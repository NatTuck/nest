defmodule Nest.Agents.Agent.InboxRenderTest do
  @moduledoc """
  The LLM-facing rendering of a drain batch, owned by
  `Nest.Agents.Agent.Inbox.Render`: what one inbox entry reads as when the
  drain delivers it to the model.

  The pure rules are the module's own contract — every body opens with its own
  `[From … | mode: M]` header (M being the mode the recipient's turn will run
  in), a `:query` adds the reply-required marker, a body with no sender still
  reads `agent`, an over-cap batch is replaced by a scratch-file pointer naming
  its first entry's id, and a delivered notice is split into its prose and its
  command output with the output's position in the row's metadata. The last
  group drives that same rendering through a real drain, so the pointer and the
  split are asserted on the text the transcript actually carries.

  The per-sender wording (a human's name, the runtime's own voice) is
  `HeaderTest`'s, and the metadata a batch rides (the human recall marker and
  the fulfilled-promise ids) is `InboxTest`'s and `TurnBackgroundingTest`'s.

  Split out of `InboxTest` (which owns the delivery/disposition contract) and
  `InboxSerializationTest` (which owns the wire shape and the selection rules)
  when `InboxTest` reached the credo source-file cap; the behavior contract is
  carried by the tests and their inline `#` comments, exactly as there.
  """

  use Nest.DataCase, async: true

  import Nest.Agents.AgentStateHelpers, only: [replace_state: 2, set_status: 2, wait_idle: 1]
  import Nest.Agents.AgentTurnTestHelpers, only: [user_texts: 1]
  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Inbox.Render
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn.Backgrounded
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Messages.Header
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Sandbox.Mounts

  # A big-enough body to exceed the default 8000-token cap.
  @oversized String.duplicate("hello world ", 4_000)

  describe "combine_and_offload/2" do
    test "a batch's bodies carry their own sender, and a query says a reply is required" do
      # intentional: the rendered text is LLM-facing. Every entry's body opens
      # with its own `[From … | mode: …]` header, so a batch disambiguates its
      # senders without an outer header; the mode is the recipient's, so the
      # fixture names a real one (`Nest.Modes.default/0`). The per-sender
      # wording — a human's name, the runtime's own voice — is `HeaderTest`'s.
      state = %Agent{live: %Agent.ChatState.Live{mode: "act"}}

      # A missing or blank sender still says `agent`: the body must not read as
      # a human's, and printing `nil` would be worse. Three bodies in one batch
      # also pin the blank line that separates them.
      assert {:ok, rendered, nil} =
               Render.combine_and_offload(
                 [
                   entry(:agent, "peer", "from an agent"),
                   entry(:agent, "", "from a blank agent"),
                   entry(:agent, nil, "from nobody")
                 ],
                 state
               )

      assert rendered ==
               "[From agent peer | mode: act]\nfrom an agent\n\n" <>
                 "[From agent | mode: act]\nfrom a blank agent\n\n" <>
                 "[From agent | mode: act]\nfrom nobody"

      # A query is a peer's words and says so (decision 7): it is the one kind
      # that obliges an answer.
      assert Render.combine_and_offload([entry(:query, "peer", "may I ask?")], state) ==
               {:ok, "[From agent peer, agents-send reply required | mode: act]\nmay I ask?", nil}
    end

    test "an over-cap batch is offloaded to a file named after its first entry's id" do
      # intentional: requirement 4 — the id is on the pointer's path too, so the
      # file is traceable to the entry it carries.
      dir = Path.join(System.tmp_dir!(), "inbox-id-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> rm_tmp!(dir, "inbox-id-") end)

      state = %Agent{name: "offload-id", space_id: 1, mounts: Mounts.new(nil, dir)}
      first = %{entry(:agent, "peer", "hello world", nil, "firstid") | content: @oversized}

      assert {:ok, content, parts} = Render.combine_and_offload([first], state)

      # The pointer is the runtime's own sentence about the batch, so the row
      # states the runtime — a headerless row renders as "unknown sender" (#195).
      assert content =~ "[From nest runtime | mode: act]"
      assert content =~ "agent-inbox-firstid.txt"
      assert parts == [{:text, content}]

      # The file keeps the whole rendered batch, headers and bodies, so the
      # senders are recoverable there.
      file = File.read!(Path.join(dir, "agent-inbox-firstid.txt"))
      assert file =~ "hello world"
      assert file =~ "[From agent peer | mode: act]"
    end

    test "a batch that is over the cap and cannot be filed is an error, not an inline copy" do
      # The same rule `admit_single/2` follows: nothing is inlined over the
      # budget to rescue the drain, and nothing is dropped. The caller keeps the
      # batch queued and surfaces the reason (`Turn.Drain.failed/2`).
      dir =
        Path.join(
          System.tmp_dir!(),
          "inbox-batch-no-write-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      on_exit(fn ->
        # The directory is made unwritable below, so cleanup has to be able to
        # open it again.
        File.chmod(dir, 0o700)
        rm_tmp!(dir, "inbox-batch-no-write-")
      end)

      # A read-only directory: the scratch write fails every time, so the
      # outcome does not depend on timing or on trying it again.
      File.chmod!(dir, 0o500)

      state = %Agent{name: "batch-no-write", space_id: 1, mounts: Mounts.new(nil, dir)}
      first = %{entry(:agent, "peer", "hello world", nil, "firstid") | content: @oversized}

      assert {:error, reason} = Render.combine_and_offload([first], state)
      assert reason =~ "could not be written"
      assert reason =~ "tokens"
    end
  end

  describe "admit_single/2" do
    test "a message over the cap becomes a pointer to the scratch file" do
      # The same admission a drained batch gets, for the paths that deliver one
      # message: an idle `chat:message`, a spawn kickoff. A body over the
      # configured cap is filed rather than allowed to force a compaction.
      dir = Path.join(System.tmp_dir!(), "inbox-single-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> rm_tmp!(dir, "inbox-single-") end)

      state = %Agent{name: "single", space_id: 1, mounts: Mounts.new(nil, dir)}

      message =
        {:user, %User{parts: [%Part.Text{text: @oversized}], metadata: %{"mode" => "act"}}}

      assert {:ok, {:user, %User{parts: [%Part.Text{text: pointer}]} = delivered}} =
               Render.admit_single(message, state)

      assert pointer =~ "Your message was too large"
      assert pointer =~ "saved to"
      # The pointer replaced the message's own text — header included — so the
      # row states the runtime, which is who is saying it was too large.
      assert pointer =~ "[From nest runtime | mode: act]"
      # The body is in the file, whole, and the delivered row is the pointer.
      assert Enum.any?(File.ls!(dir), fn name ->
               File.read!(Path.join(dir, name)) == @oversized
             end)

      assert delivered.metadata == %{"mode" => "act"}
    end

    test "a message that fits is delivered unchanged" do
      dir = Path.join(System.tmp_dir!(), "inbox-single-fit-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> rm_tmp!(dir, "inbox-single-fit-") end)

      state = %Agent{name: "single-fit", space_id: 1, mounts: Mounts.new(nil, dir)}
      message = {:user, %User{parts: [%Part.Text{text: "hello"}], metadata: %{}}}

      assert Render.admit_single(message, state) == {:ok, message}
      assert File.ls!(dir) == []
    end

    test "a message that cannot be filed is a clear error, not an inline copy" do
      # No scratch dir: the write fails, and the answer is an error naming the
      # size. Inlining it would only move the failure to the send gate, which is
      # a never-happen tripwire rather than a place to absorb an oversized body.
      state = %Agent{name: "single-no-scratch", space_id: 1, mounts: Mounts.new(nil, nil)}
      message = {:user, %User{parts: [%Part.Text{text: @oversized}], metadata: %{}}}

      assert {:error, reason} = Render.admit_single(message, state)
      assert reason =~ "could not be written"
    end
  end

  describe "build_drained_message/3" do
    test "an entry that claims a composed source on a non-user kind is not tagged as the human's" do
      # The recall-list marker is fail-closed on the client and needs both
      # halves — `kind: :user` *and* a human `source` — so a `:runtime` entry
      # that claimed one stays untagged instead of being mistagged as the
      # human's own words. (The tagged human batch is `InboxTest`'s; the
      # fulfilled-promise ids that ride this same message are
      # `TurnBackgroundingTest`'s.)
      notice = entry(:runtime, nil, "runtime note", nil, nil, true)

      assert {:user, %{metadata: metadata}} =
               Render.build_drained_message([notice], "runtime note", nil, "chat")

      assert metadata == %{"mode" => "chat"}
    end

    test "a worker's death is one text part and carries no marker" do
      # There is no output to show, so there is nothing to render verbatim: one
      # part, and the key is omitted entirely rather than sent empty.
      notice = notice_entry({:worker_down, :killed})
      assert {:ok, content, nil} = Render.combine_and_offload([notice], render_state("act"))

      assert {:user, %User{parts: [%Part.Text{}], metadata: metadata}} =
               Render.build_drained_message([notice], content, nil, "act")

      refute Map.has_key?(metadata, "command_output_parts")
    end

    test "an offloaded batch is the runtime's pointer alone, with no marker" do
      # The pointer replaced the whole text, so the command output is in the
      # scratch file rather than in the row: one text part carrying the
      # runtime's header (it is the runtime's sentence), and no
      # `commandOutputParts` — there is no output part for it to name.
      dir = Path.join(System.tmp_dir!(), "inbox-notice-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> rm_tmp!(dir, "inbox-notice-") end)

      state = %Agent{name: "offload-notice", space_id: 1, mounts: Mounts.new(nil, dir)}
      notice = notice_entry({:results, [%{name: "shell-cmd", content: @oversized}]})

      assert {:ok, content, parts} = Render.combine_and_offload([notice], state)
      # The batch really was offloaded: the delivered content is the pointer,
      # whose singular wording is pinned on the transcript by the drain test.
      assert content =~ "saved to"
      assert parts == [{:text, content}]

      # The parts are the ones the offload stated, not a re-render of the batch:
      # the row is the pointer, so its join is the pointer.
      assert {:user, %User{parts: [%Part.Text{text: pointer}], metadata: metadata}} =
               Render.build_drained_message([notice], content, parts, "act")

      assert pointer == content
      assert pointer =~ "[From nest runtime | mode: act]"
      refute Map.has_key?(metadata, "command_output_parts")
    end
  end

  describe "parts/2" do
    test "a notice entry's header heads its first segment, keeping the output's kind" do
      # issue #139: the header is a prefix, so applying it to the first segment
      # puts it at the head of the body exactly as before — and keeps it off the
      # command output, which is the point of splitting at all. (The notice's
      # own wording is `BackgroundedTest`'s.)
      notice = notice_entry({:results, [%{name: "shell-cmd", content: "# output\n"}]})

      assert [
               {:text, "[From nest runtime | mode: act]\n" <> prose},
               {:output, "# output\n"}
             ] = Render.parts([notice], "act")

      # An entry with no segments of its own renders exactly as it always did,
      # and the blank line between entries rides the *last* segment of the
      # earlier one, keeping its kind.
      peer = entry(:agent, "peer", "hi")

      assert Render.parts([peer, notice], "act") == [
               {:text, "[From agent peer | mode: act]\nhi\n\n"},
               {:text, "[From nest runtime | mode: act]\n" <> prose},
               {:output, "# output\n"}
             ]
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
      # and a human's alike. The pointer still carries the body's header,
      # because that is rendered when the batch is built, and the batch's one
      # entry is its one body.
      cases = [
        {"a peer's message", "[From agent alice",
         fn pid -> assert {:ok, :queued} = Agent.deliver_note(pid, "alice", @oversized) end},
        {"a human's message", "[From user @alice | mode: plan]",
         fn pid -> assert :ok = Agent.chat(pid, @oversized, "plan", "alice", :composed) end}
      ]

      for {{label, header, deliver}, n} <- Enum.with_index(cases, 1) do
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

        # The pointer is the runtime's own sentence about the batch, so the row
        # states the runtime: a headerless user row is what renders as "unknown
        # sender" (#195). The *body's* header is what went to the file.
        assert pointer =~ "[From nest runtime | mode: "

        # One scratch file per delivery, holding the batch's whole text — and
        # therefore the body's header, which the model reads back there.
        files = Path.wildcard(Path.join(Mounts.scratch(state.mounts), "agent-inbox-*.txt"))
        assert length(files) == n, label
        assert Enum.all?(files, &(File.read!(&1) =~ "hello world"))
        assert Enum.any?(files, &(File.read!(&1) =~ header)), label

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

      assert {:ok, :queued} = Agent.deliver_note(pid, "alice", @oversized)
      assert_receive {:chat_inbox, %{count: 1}}, 1_000
      assert {:ok, :queued} = Agent.deliver_note(pid, "bob", @oversized)
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

    test "a backgrounded notice reaches the transcript as two parts, the output marked", %{
      pid: pid
    } do
      # issue #139, end to end: the row the drain appends is the notice split
      # into its prose and its command output, and its metadata names the output
      # part — which is what the browser needs to stop rendering the output as
      # markdown. The row's text behind its header is still the notice exactly.
      before = Agent.get_public_info(pid, 1_000).message_count
      notice = notice_entry({:results, [%{name: "shell-cmd", content: "# output\n"}]})

      # A live turn carrying the notice, so `stop_chat` reaches the idle
      # transition that drains — the shape a backgrounded result is queued in.
      replace_state(pid, fn state ->
        %{
          state
          | live: %{
              state.live
              | inbox: [notice],
                machine: Machine.status_to_machine(state.live.machine, :streaming)
            }
        }
      end)

      Agent.stop_chat(pid, self())

      # The drain appends the message before it consumes the entry, so the
      # consume frame is the fence for it being in the transcript.
      assert_receive {:chat_inbox, %{count: 0}}, 1_000

      assert [{:user, %User{parts: parts, metadata: metadata}}] =
               Agent.get_messages(pid, 1_000)
               |> Enum.drop(before)
               |> Enum.filter(&match?({:user, _}, &1))

      assert [%Part.Text{text: first}, %Part.Text{text: "# output\n"}] = parts
      assert String.starts_with?(first, "[From nest runtime | mode: ")
      assert Header.body(Enum.map_join(parts, "", & &1.text)) == notice.content
      assert metadata["command_output_parts"] == [1]

      wait_idle(pid)
    end
  end

  defp entry(kind, from, content, mode \\ nil, id \\ nil, source \\ false) do
    %{
      id: id || Inbox.new_id(),
      from: from,
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: mode,
      source: source,
      fulfilled_ids: []
    }
  end

  # A `:runtime` entry as `Inbox.enqueue_runtime/3` builds it: the outcome's
  # segments, and a content that is their join. The two are derived from one
  # source here for the same reason the producer derives them from one source —
  # so a test cannot accidentally assert a split that disagrees with the text.
  defp notice_entry(outcome) do
    parts = Backgrounded.parts(outcome)

    :runtime
    |> entry(nil, Enum.map_join(parts, "", &elem(&1, 1)))
    |> Map.put(:parts, parts)
  end

  # The state `combine_and_offload/2` needs for a batch that is not over the cap:
  # only the mode, which is what the headers state.
  defp render_state(mode), do: %Agent{live: %Agent.ChatState.Live{mode: mode}}
end
