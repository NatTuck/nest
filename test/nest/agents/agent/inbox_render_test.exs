defmodule Nest.Agents.Agent.InboxRenderTest do
  @moduledoc """
  The LLM-facing rendering of a drain batch, owned by
  `Nest.Agents.Agent.Inbox.Render`: what one inbox entry reads as when the
  drain delivers it to the model.

  The pure rules are the module's own contract — a human entry and a runtime
  `:notice` render bare, every other kind keeps its `[Message from agent "X" |
  mode: M]` label (M being the mode the recipient's turn will run in), an
  over-cap batch is replaced by a scratch-file pointer, and the delivered
  message carries the batch's metadata. The last group drives that same
  rendering through a real drain, so the pointer is asserted on the text the
  transcript actually carries.

  Split out of `InboxTest` (which owns the delivery/disposition contract) and
  `InboxSerializationTest` (which owns the wire shape and the selection rules)
  when `InboxTest` reached the credo source-file cap; the behavior contract is
  carried by the tests and their inline `#` comments, exactly as there.
  """

  use Nest.DataCase, async: true

  import Nest.Agents.AgentStateHelpers, only: [set_status: 2, wait_idle: 1]
  import Nest.Agents.AgentTurnTestHelpers, only: [user_texts: 1]
  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Inbox.Render
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Messages.MessageList
  alias Nest.Sandbox.Mounts

  # A big-enough body to exceed the default 8000-token cap.
  @oversized String.duplicate("hello world ", 4_000)

  describe "combine_and_offload/2" do
    test "a human entry renders bare, a runtime notice carries the notice tag, every other kind keeps its label" do
      # intentional: the rendered text is LLM-facing. A human entry is its bare
      # content (its `[mode: X]` prefix is added when the message is built), so
      # a queued human message reads exactly like one that arrived while the
      # agent was idle. Agent entries keep `[Message from agent "X"]`, which is
      # what disambiguates a batch; a missing or blank sender drops the quoted
      # name rather than printing `nil` or `""`. A runtime notice has no label
      # (no agent said it) but does carry the `[nest notice]` marker at the head
      # of its own text, which is what tells the model the body is the runtime's.
      # The label also states the mode the recipient's turn will run in, so the
      # fixture names a real one (`Nest.Modes.default/0`).
      state = %Agent{live: %Agent.ChatState.Live{mode: "act"}}

      assert Render.combine_and_offload([entry(:user, "alice", "from a human", "plan")], state) ==
               "from a human"

      assert Render.combine_and_offload([entry(:user, nil, "from nobody")], state) ==
               "from nobody"

      assert Render.combine_and_offload(
               [
                 entry(:agent, "peer", "from an agent"),
                 entry(:agent, "", "from a blank agent"),
                 entry(:agent, nil, "from nobody")
               ],
               state
             ) ==
               "[Message from agent \"peer\" | mode: act]\nfrom an agent\n\n" <>
                 "[Message from agent | mode: act]\nfrom a blank agent\n\n" <>
                 "[Message from agent | mode: act]\nfrom nobody"

      # A query is a peer's words and keeps the label (decision 7); a notice
      # is the runtime's own and must never be framed as an agent's (decision
      # 9) — it carries no label, exactly like a human's, plus the notice
      # marker the client strips on render.
      assert Render.combine_and_offload([entry(:query, "peer", "may I ask?")], state) ==
               "[Message from agent \"peer\" | mode: act]\nmay I ask?"

      assert Render.combine_and_offload([entry(:notice, "peer", "peer never answered")], state) ==
               "[nest notice]\npeer never answered"
    end

    test "an over-cap batch is offloaded to a file named after its first entry's id" do
      # intentional: requirement 4 — the id is on the pointer's path too, so the
      # file is traceable to the entry it carries.
      dir = Path.join(System.tmp_dir!(), "inbox-id-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> rm_tmp!(dir, "inbox-id-") end)

      state = %Agent{name: "offload-id", space_id: 1, mounts: Mounts.new(nil, dir)}
      first = %{entry(:agent, "peer", "hello world", nil, "firstid") | content: @oversized}

      content = Render.combine_and_offload([first], state)
      assert content =~ "agent-inbox-firstid.txt"
      assert File.read!(Path.join(dir, "agent-inbox-firstid.txt")) =~ "hello world"
    end
  end

  describe "build_drained_message/3" do
    test "the batch's metadata rides the message, and only a human batch is tagged" do
      # intentional: the delivered message carries the batch's metadata and
      # nothing else. The recall-list marker is fail-closed on the client, so
      # `origin` is written only for a batch whose head is `kind: :user` *and*
      # `human?: true` — an ordinary delivery and a `:notice` that claimed
      # `human?` stay untagged rather than being mistagged as the human's own
      # words — while the backgrounded-promise metadata that already rides this
      # message survives the merge.
      cases = [
        {"a human batch", [entry(:user, "alice", "hi", "plan", nil, true)], "hi", "plan",
         %{"mode" => "plan", "origin" => "human"}},
        {"a delivered batch", [%{entry(:agent, "peer", "do it") | fulfilled_ids: ["c1", "c2"]}],
         "do it", "chat",
         Map.merge(%{"mode" => "chat"}, MessageList.fulfilled_metadata(["c1", "c2"]))},
        {"a non-user entry that claims human?",
         [entry(:notice, nil, "runtime note", nil, nil, true)], "runtime note", "chat",
         %{"mode" => "chat"}}
      ]

      for {label, entries, content, mode, expected} <- cases do
        assert {:user, %{metadata: metadata}} =
                 Render.build_drained_message(entries, content, mode)

        assert metadata == expected, label
      end
    end
  end

  describe "the rendering a real drain delivers" do
    setup do
      # Modes `plan` and `review` on top of the `chat` default, so the human
      # case below can request a mode the agent is not already in.
      {pid, name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: AgentTestHelpers.multi_mode_vocation_id_for_test()
        })

      %{pid: pid, name: name}
    end

    test "an over-cap batch reaches the transcript as a scratch-file pointer", %{pid: pid} do
      # intentional: an over-cap batch is not delivered inline — the model is
      # given a pointer naming the file the text went to — for a peer's message
      # and a human's alike. The human's pointer still carries its
      # `[mode: plan]` prefix, because that is added when the delivered message
      # is built, not when the batch is rendered.
      cases = [
        {"a peer's message", nil,
         fn pid -> assert {:ok, :queued} = Agent.deliver_message(pid, "alice", @oversized) end},
        {"a human's message", "plan",
         fn pid -> assert :ok = Agent.chat(pid, @oversized, "plan", "alice") end}
      ]

      for {{label, mode, deliver}, n} <- Enum.with_index(cases, 1) do
        before = Agent.get_public_info(pid, 1_000).message_count
        set_status(pid, :streaming)
        deliver.(pid)
        assert_receive {:chat_inbox, %{count: 1}}, 1_000

        Agent.stop_chat(pid, self())

        # The drain appends the pointer before it consumes the entry, so the
        # consume frame is the fence for the pointer being in the transcript.
        assert_receive {:chat_inbox, %{count: 0}}, 1_000
        # allowlist: snapshot — messages + tmp_path
        state = :sys.get_state(pid, 1_000)

        appended =
          state.chat_state.messages
          |> Enum.drop(before)
          |> user_texts()

        assert [pointer] = Enum.filter(appended, &(&1 =~ "queued message" and &1 =~ "saved to")),
               label

        assert pointer =~ "You have 1 queued message"

        if mode do
          assert pointer =~ "[mode: #{mode}]", label
        end

        # One scratch file per delivery, holding the batch's whole text.
        files = Path.wildcard(Path.join(Mounts.scratch(state.mounts), "agent-inbox-*.txt"))
        assert length(files) == n, label
        assert Enum.all?(files, &(File.read!(&1) =~ "hello world"))

        wait_idle(pid)
      end
    end

    test "an over-cap batch of two entries names the count in the plural pointer", %{pid: pid} do
      # intentional: `pointer/2`'s plural clause. A batch is a run of leading
      # non-human entries delivered as one message, so two oversized peer
      # messages queue together and are offloaded as one batch. The pointer has
      # to say how many bodies went to the file — the model reads them all back
      # there, and "1 queued message" would understate what it is missing.
      before = Agent.get_public_info(pid, 1_000).message_count
      set_status(pid, :streaming)

      assert {:ok, :queued} = Agent.deliver_message(pid, "alice", @oversized)
      assert_receive {:chat_inbox, %{count: 1}}, 1_000
      assert {:ok, :queued} = Agent.deliver_message(pid, "bob", @oversized)
      assert_receive {:chat_inbox, %{count: 2}}, 1_000

      Agent.stop_chat(pid, self())

      # The drain appends the pointer before it consumes the entries, so the
      # consume frame is the fence for the pointer being in the transcript.
      assert_receive {:chat_inbox, %{count: 0}}, 1_000
      # allowlist: snapshot — messages + tmp_path
      state = :sys.get_state(pid, 1_000)

      appended =
        state.chat_state.messages
        |> Enum.drop(before)
        |> user_texts()

      assert [pointer] = Enum.filter(appended, &(&1 =~ "queued message" and &1 =~ "saved to"))

      assert pointer =~ "You have 2 queued messages"
      assert pointer =~ "Read that file to see them"

      # One scratch file for the whole batch, holding both entries' text.
      assert [file] = Path.wildcard(Path.join(Mounts.scratch(state.mounts), "agent-inbox-*.txt"))
      assert File.read!(file) =~ "hello world"

      wait_idle(pid)
    end
  end

  defp entry(kind, from, content, mode \\ nil, id \\ nil, human? \\ false) do
    %{
      id: id || Inbox.new_id(),
      from: from,
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: mode,
      human?: human?,
      fulfilled_ids: []
    }
  end
end
