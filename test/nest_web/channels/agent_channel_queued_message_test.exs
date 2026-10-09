defmodule NestWeb.AgentChannelQueuedMessageTest do
  @moduledoc """
  `chat:message` disposition for an agent that cannot start a turn right now:
  a busy agent (`:streaming`, `:executing_tools`, `:compacting`) queues the
  message — with the sender and the requested mode — for its next turn
  boundary, while a broken status is still refused and queues nothing.

  The `:compacting` case lives in `agent_channel_chat_test.exs` (beside the
  other status-disposition tests); this file covers the rest.
  """

  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias NestWeb.AgentChannel
  alias NestWeb.UserSocket

  setup :verify_on_exit!

  describe "chat:message dispositions" do
    test "a busy agent queues the message; a broken agent still refuses it", %{
      socket: socket,
      agent_id: id,
      space_id: space_id,
      user: user
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      # A busy agent queues the message for its next turn boundary — the
      # reply is `{:ok, _}`, not `agent_busy`, and the entry records the
      # sender and the requested mode verbatim (the mode is applied when the
      # message is delivered).
      for {status, n} <- Enum.with_index([:streaming, :executing_tools], 1) do
        set_status(agent_pid, status)
        content = "queued #{status}"

        ref = push(socket, "chat:message", %{"content" => content, "mode" => "plan"})
        assert_reply ref, :ok, %{}

        state = :sys.get_state(agent_pid)

        assert length(state.live.inbox) == n
        assert Machine.status_for(state.live.machine) == status

        assert %{content: ^content, kind: :user, from: from, mode: "plan"} =
                 List.last(state.live.inbox)

        assert from == user.username
      end

      # The queued human entries travel on the wire with their kind and mode,
      # and `pendingMessageCount` counts them.
      ref = push(socket, "chat:inbox", %{})
      assert_reply ref, :ok, %{"count" => 2, "messages" => messages}

      assert Enum.map(messages, &Map.take(&1, ["from", "content", "kind", "mode"])) == [
               %{
                 "from" => user.username,
                 "content" => "queued streaming",
                 "kind" => "user",
                 "mode" => "plan"
               },
               %{
                 "from" => user.username,
                 "content" => "queued executing_tools",
                 "kind" => "user",
                 "mode" => "plan"
               }
             ]

      assert Enum.all?(messages, &(is_binary(&1["timestamp"]) and &1["timestamp"] != ""))

      # The status reply carries the same count, so a reconnecting client
      # sees the queued human message.
      ref = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref, :ok, %{"pendingMessageCount" => 2}

      # A broken status still refuses the message and queues nothing new.
      before = :sys.get_state(agent_pid).live.inbox
      set_status(agent_pid, :needs_repair)

      ref = push(socket, "chat:message", %{"content" => "too late", "mode" => "plan"})
      assert_reply ref, :error, %{"reason" => "agent_status_needs_repair"}

      assert :sys.get_state(agent_pid).live.inbox == before
    end
  end

  describe "malformed chat:message payloads" do
    test "non-string or missing content is refused; a non-string mode means no mode", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)
      set_status(agent_pid, :streaming)

      # A map content would otherwise reach the agent and crash it when the
      # user message is built (idle) or the queue is combined (busy).
      ref = push(socket, "chat:message", %{"content" => %{"a" => 1}})
      assert_reply ref, :error, %{"reason" => "invalid_content"}

      # A payload with no content key used to match no clause at all, raising
      # inside the channel server.
      ref = push(socket, "chat:message", %{"mode" => "plan"})
      assert_reply ref, :error, %{"reason" => "invalid_content"}

      assert :sys.get_state(agent_pid).live.inbox == []

      # A non-binary mode is normalized to nil, so the wire contract stays
      # string-or-null.
      ref = push(socket, "chat:message", %{"content" => "hello", "mode" => 123})
      assert_reply ref, :ok, %{}

      state = :sys.get_state(agent_pid)
      assert [%{content: "hello", kind: :user, mode: nil}] = state.live.inbox

      reset_to_idle(agent_pid)
    end
  end

  describe "composed channel -> queue -> drain path" do
    test "a human message pushed while a tool batch runs is queued and delivered alone",
         %{
           user: user
         } do
      test_pid = self()

      # A dedicated agent on a multi-mode vocation: the queued message asks for
      # `plan`, which only resolves if the vocation defines it (the helper's own
      # agent is single-mode `chat`). It is joined below through the real
      # channel, so the whole path is the client's.
      {agent_pid, name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: AgentTestHelpers.multi_mode_vocation_id_for_test(),
          created_by_user_id: user.id
        })

      space_id = AgentTestHelpers.current_space_id()
      {:ok, connected} = connect(UserSocket, %{"token" => Process.get(:agent_test_token)})
      {:ok, _, socket} = subscribe_and_join(connected, AgentChannel, "agent:#{space_id}:#{name}")

      # Park a real tool batch inside `Agents.send_message/4` (the `agents-send`
      # entry point) until we release it, so the human push below lands while
      # the agent is genuinely `:executing_tools`. The `after` is a safety valve
      # so a failing test cannot leave the tool worker parked.
      Mimic.stub(Nest.Agents, :send_message, fn space, from, target, content ->
        send(test_pid, {:tool_batch_blocked, self()})

        receive do
          :release_tools -> :ok
        after
          1_000 -> :ok
        end

        Mimic.call_original(Nest.Agents, :send_message, [space, from, target, content])
      end)

      Mimic.allow(Nest.Agents, self(), agent_pid)

      MockClient.set_tool_response(%{
        text: "Calling a tool",
        tool_calls: [
          %{
            id: "send_1",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "peer note"}
          }
        ]
      })

      MockClient.set_response("Done")

      ref = push(socket, "chat:message", %{"content" => "start the turn"})
      assert_reply ref, :ok, %{}
      assert_receive {:tool_batch_blocked, worker}, 500

      # The human push: accepted while busy, queued with the socket's username,
      # the requested mode and the verbatim content (no mode prefix).
      ref = push(socket, "chat:message", %{"content" => "human note", "mode" => "plan"})
      assert_reply ref, :ok, %{}

      state = :sys.get_state(agent_pid)

      assert [%{kind: :user, from: from, mode: "plan", content: "human note"}] = state.live.inbox
      assert from == user.username
      assert Machine.status_for(state.live.machine) == :executing_tools

      send(worker, :release_tools)

      # The batch completes (queueing the peer's `agents-send` entry behind the
      # human's), and that status broadcast carries the queued count, so a
      # client that missed a `chat:inbox` frame can recover it.
      assert_push "chat:status", %{status: "streaming", pendingMessageCount: 2}, 500

      # The boundary drain delivers the human message ALONE — it never merges
      # with the peer entry that arrived behind it (issue #31 decision 8) — as
      # bare human text in the human's mode, with no sender framing: a queued
      # human message must read exactly like one typed while the agent was idle.
      # `"mode" => "plan"` distinguishes it from the turn-opening message
      # (`"mode" => "chat"`). The test process is subscribed twice (the helper's
      # `start_agent/1` plus this join), so every broadcast arrives twice —
      # assertions match payloads, never sequences.
      assert_push "chat:message",
                  %{"role" => "user", "mode" => "plan", "parts" => [%{"text" => human_text}]} =
                    delivered,
                  500

      assert is_integer(delivered["index"])
      assert human_text == "[mode: plan]\nhuman note"

      # The peer's entry is delivered as its own batch at the next turn
      # boundary, with the agent label that disambiguates it.
      assert_push "chat:message",
                  %{
                    "role" => "user",
                    "parts" => [%{"text" => "[mode: plan]\n[Message from agent \"" <> rest}]
                  },
                  500

      assert rest == "#{name}\"]\npeer note"

      # Both delivered turns ran to completion, so the transcript is: the
      # turn-opening user message, the tool call and its result, the live bridge
      # ack, the delivered human message, its response, the delivered peer
      # message, and its response.
      assert Eventually.eventually(
               fn ->
                 :sys.get_state(agent_pid).chat_state.messages
                 |> Enum.map(&elem(&1, 0)) ==
                   [
                     :system,
                     :user,
                     :assistant,
                     :tool,
                     :assistant,
                     :user,
                     :assistant,
                     :user,
                     :assistant
                   ]
               end,
               timeout: 500
             )

      state = :sys.get_state(agent_pid)
      messages = state.chat_state.messages

      ack_index = Enum.find_index(messages, &(text_of(&1) =~ "continuing from here"))
      human_index = Enum.find_index(messages, &(text_of(&1) =~ "human note"))
      peer_index = Enum.find_index(messages, &(text_of(&1) =~ "peer note"))

      assert is_integer(ack_index), "expected the bridge ack"
      assert is_integer(human_index), "expected the delivered human message"
      assert is_integer(peer_index), "expected the delivered peer message"
      assert ack_index < human_index
      assert human_index < peer_index
      assert human_index == delivered["index"]
      assert text_of(Enum.at(messages, human_index)) == "[mode: plan]\nhuman note"

      assert state.live.inbox == []
      assert Machine.status_for(state.live.machine) == :idle
      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  describe "a queued message across a compaction (#26)" do
    test "the queue survives the compaction and clears only when the message is delivered",
         %{user: user} do
      test_pid = self()

      # A dedicated agent on a multi-mode vocation: the queued message asks for
      # `plan`, which only resolves if the vocation defines it.
      {agent_pid, name} =
        AgentTestHelpers.start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: AgentTestHelpers.multi_mode_vocation_id_for_test(),
          created_by_user_id: user.id
        })

      space_id = AgentTestHelpers.current_space_id()
      {:ok, connected} = connect(UserSocket, %{"token" => Process.get(:agent_test_token)})
      {:ok, _, socket} = subscribe_and_join(connected, AgentChannel, "agent:#{space_id}:#{name}")

      # Park the compactor's LLM call, so the agent stays `:compacting` while the
      # human push lands — no timing dependence. The `after` is a safety valve
      # so a failing test cannot leave the compactor parked.
      Mimic.stub(MockClient, :run, fn request, opts ->
        if compaction_request?(request) do
          send(test_pid, {:compactor_blocked, self()})

          receive do
            :release_compactor -> :ok
          after
            1_000 -> :ok
          end
        end

        Mimic.call_original(MockClient, :run, [request, opts])
      end)

      Mimic.allow(MockClient, self(), agent_pid)

      # The model asks for a compaction: staging it refuses the tool batch and
      # carries the turn's continuation, so the agent reports `:compacting`.
      MockClient.set_tool_response(%{
        text: "compacting",
        tool_calls: [%{id: "c1", name: "context-compact", arguments: %{}}]
      })

      MockClient.set_response("Done")

      ref = push(socket, "chat:message", %{"content" => "start the turn"})
      assert_reply ref, :ok, %{}
      assert_receive {:compactor_blocked, compactor}, 500

      # The human push queues while the agent is compacting. Nothing consumes it
      # — the compaction's resume is what delivers it — so the count stays at 1
      # for the whole compaction, and no count-0 frame is ever sent for it.
      ref = push(socket, "chat:message", %{"content" => "human note", "mode" => "plan"})
      assert_reply ref, :ok, %{}

      assert_push "chat:inbox", %{count: 1}, 500
      refute_push "chat:inbox", %{count: 0}, 100

      state = :sys.get_state(agent_pid)

      assert Machine.status_for(state.live.machine) == :compacting
      assert [%{content: "human note", kind: :user, mode: "plan"}] = state.live.inbox

      # Releasing the compactor commits the compaction: the resume re-runs the
      # carried continuation and the next turn boundary drains the queue, so the
      # message is delivered and the queue clears. The only count-0 frame in
      # this test is that consume.
      send(compactor, :release_compactor)

      assert_push "chat:inbox", %{count: 0, messages: []}, 500

      assert_push "chat:message",
                  %{"role" => "user", "mode" => "plan", "parts" => [%{"text" => text}]},
                  500

      assert text == "[mode: plan]\nhuman note"

      # The turn the delivered message started runs to completion.
      assert_push "chat:status", %{status: "idle"}, 500

      state = :sys.get_state(agent_pid)

      assert state.live.inbox == []
      assert Machine.status_for(state.live.machine) == :idle
      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  # The compactor's request ends on the `[mode: compact]` suffix, which is what
  # distinguishes it from a chat request.
  defp compaction_request?(request) do
    Enum.any?(request.messages, fn
      {:user, %{parts: parts}} ->
        Enum.any?(
          parts || [],
          &match?(%Nest.Messages.Part.Text{text: "[mode: compact]" <> _}, &1)
        )

      _ ->
        false
    end)
  end

  # Fabricate an observable status (there is no real turn behind it). The
  # test's last probe leaves the agent in a blocked status — never one of the
  # in-flight busy ones — so the teardown's zero-in-flight assertion holds.
  defp set_status(pid, status) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | machine: Machine.status_to_machine(state.live.machine, status)
          }
      }
    end)
  end

  defp text_of({_tag, %{parts: parts}}), do: AgentTestHelpers.text_from_parts(parts)

  # Undo a fabricated status and the queue it collected, so the teardown's
  # zero-in-flight assertion holds.
  defp reset_to_idle(pid) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{
            state.live
            | inbox: [],
              machine: Machine.status_to_machine(state.live.machine, :idle)
          }
      }
    end)
  end
end
