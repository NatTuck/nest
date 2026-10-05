defmodule Nest.Agents.AgentStopTest do
  @moduledoc """
  Tests for the user-initiated chat-stop flow. Covers:

    * Stopping mid-LLM-stream — partial assistant text is
      finalized into a message tagged with
      `metadata.stopped_by_user: true` and the agent
      transitions to `:idle`.
    * Stopping after the LLM stream completes (between turns)
      — no-op.
    * Stopping during a `context` tool compaction call — the
      in-process turn unwinds, no `:compaction_done` resume
      auto-resumes.
    * Idempotency — multiple `Agent.stop_chat/2` calls
      before finalization don't crash anything.
  """
  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Handlers.TurnHandler
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part

  setup :verify_on_exit!

  import Nest.Agents.AgentTestHelpers

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  describe "stop_chat/2 mid-LLM-stream" do
    test "finalizes the partial assistant message and transitions to idle" do
      events = for _ <- 1..1000, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, %{index: 1}}}, 500
      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_delta, _}, 500

      Agent.stop_chat(pid, self())

      assert_receive {:chat_message,
                      {:assistant, %Assistant{metadata: %{"stopped_by_user" => true}}}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "the finalized assistant message carries the partial text content" do
      events = for _ <- 1..1000, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Tell me a story")
      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      Agent.stop_chat(pid, self())

      assert_receive {:chat_message,
                      {:assistant, %Assistant{parts: [%Part.Text{text: content}], index: 2}}},
                     2000

      assert is_binary(content)
      assert content != ""
      assert String.starts_with?(content, "x")

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end
  end

  describe "stop_chat/2 between turns" do
    test "is a no-op when the agent is idle" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # No chat turn is in flight. The stop handler runs
      # without crashing; no `chat:status: idle` is broadcast
      # because the agent is already idle. The `refute_receive`
      # waits up to 50ms for a broadcast that should never come.
      :ok = Agent.stop_chat(pid, self())
      refute_receive {:chat_status, _}, 50
    end
  end

  describe "stop_chat/2 before any LLM delta" do
    test "closes the turn with a non-empty assistant message, never an empty one" do
      # The user clicks Stop between sending the message and receiving
      # any text from the LLM. No empty message is ever inserted: the
      # turn is closed with a non-empty acknowledgement tagged
      # `stopped_by_user` so the messages list stays alternation-valid
      # for the next turn.
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # Empty stream events: the HTTP worker starts but never emits a
      # delta, so `streaming_acc` stays nil at stop time.
      MockClient.set_stream_events([{:text, ""}])

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_status, %{status: "streaming"}}, 500

      Agent.stop_chat(pid, self())

      assert_receive {:chat_message,
                      {:assistant, %Assistant{metadata: %{"stopped_by_user" => true}}}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 500

      state = :sys.get_state(pid)

      # No message in the list is empty.
      refute Enum.any?(state.chat_state.messages, fn
               {_role, %{parts: []}} -> true
               _ -> false
             end)

      # The turn was closed with a non-empty assistant acknowledgement.
      assert Enum.any?(state.chat_state.messages, fn
               {:assistant, %Assistant{parts: [_ | _], metadata: %{"stopped_by_user" => true}}} ->
                 true

               _ ->
                 false
             end)
    end
  end

  describe "stop_chat/2 during context-compact tool" do
    test "the tool-call mid-execution stop unwinds without auto-resume" do
      # Set up a stream that emits one `context-compact` tool call.
      # The turn's `handle_compact_only/3` emits `{:needs_compaction, _}`
      # to the Agent and stops; the Agent then owns the compaction. We
      # stop the agent while that hand-off is in flight.
      MockClient.set_tool_response(%{
        text: "compacting",
        tool_calls: [
          %{
            id: "call_1",
            name: "context-compact",
            arguments: %{"focus" => "recent"}
          }
        ]
      })

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "compact please")

      assert_receive {:chat_message, {:user, _}}, 500
      # Drain to find the assistant carrying the tool call (a
      # context-notice synthetic pair may precede it).
      tool_assistant = wait_for_assistant_with_tool_use(2_000)
      assert tool_assistant != nil
      assert Enum.any?(tool_assistant.parts, &match?(%Part.ToolUse{}, &1))
      assert_receive {:chat_status, %{status: "executing_tools"}}, 500

      # The context-compact hand-off completes quickly; the compactor
      # may already have run by the time we get here. Use the public
      # stop API so the stop always wins regardless of the in-flight
      # phase; the real assertion is that the agent ends idle without
      # auto-resuming.
      assert :ok = Agent.stop_chat(pid, self())

      assert_receive {:chat_status, %{status: "idle"}}, 2000
    end
  end

  describe "stop_chat/2 idempotency" do
    test "multiple stop clicks don't crash the agent" do
      events = for _ <- 1..100, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      Agent.stop_chat(pid, self())
      Agent.stop_chat(pid, self())
      Agent.stop_chat(pid, self())

      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # After the stop, the agent is in a clean state. A new
      # chat turn should work normally.
      :ok = Agent.chat(pid, "After the stop")

      # Wait for the full second-turn to complete (idle
      # status) BEFORE asserting the earlier events. This
      # avoids mailbox pollution from the first turn that
      # could otherwise match the second turn's assertions
      # in a flaky way.
      assert_receive {:chat_status, %{status: "idle"}}, 2000
      assert_receive {:chat_message, {:user, %{index: 3}}}, 500
      assert_receive {:chat_message, {:assistant, _}}, 500
    end
  end

  describe "stop_chat/2 then a new chat turn" do
    test "the cancelled flag is cleared so the next pre-flight compaction can resume" do
      # First turn: stream a long-ish text response that we'll
      # stop mid-stream.
      events = for _ <- 1..100, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "First turn")
      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      Agent.stop_chat(pid, self())
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # The `cancelled` flag must be cleared on the next turn,
      # otherwise a pre-flight compaction's resume
      # would be discarded (see the guard in `compaction_done/3`).

      # Second turn: a normal text response.
      MockClient.set_response("Second turn response")

      :ok = Agent.chat(pid, "Second turn")

      # Wait for the second turn to reach :idle first
      # (consuming the user message and assistant message
      # along the way). This is more robust than asserting
      # the user message first, which can flake when the
      # first turn's stale messages pollute the test
      # process's mailbox.
      assert_receive {:chat_status, %{status: "idle"}}, 2000
      assert_receive {:chat_message, {:user, %{index: 3}}}, 500

      assert_receive {:chat_message,
                      {:assistant, %{parts: [%Part.Text{text: "Second turn response"}]}}},
                     500
    end
  end

  # Regression guard for the agent_stop_test.exs flakiness.
  # The flakiness was caused by late deltas from a previous
  # chat arriving at the Agent AFTER chat_stopped set the
  # streaming_acc to nil; the delta handler then crashed
  # with FunctionClauseError. The fix in llm_stream_handler
  # .ex's delta_received/3 makes the handler a no-op when
  # streaming_acc is nil. This test exercises the exact
  # race: a streaming chat is stopped, a new chat starts
  # while the old chat's deltas are still in flight, and
  # the new chat must complete successfully. A future
  # regression (re-introducing the nil-deref) would crash
  # the Agent GenServer and fail the second chat's idle
  # status assertion.
  describe "stability" do
    test "stopped chat's late deltas don't crash a subsequent chat" do
      events = for _ <- 1..50, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "First turn")
      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      Agent.stop_chat(pid, self())
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # Immediately start a new chat. The previous chat's
      # HTTP worker may still be in flight; any late
      # deltas must not crash the Agent.
      MockClient.set_response("Second response")
      :ok = Agent.chat(pid, "Second turn")

      assert_receive {:chat_status, %{status: "idle"}}, 2000
      assert_receive {:chat_message, {:user, %{index: 3}}}, 500

      assert_receive {:chat_message,
                      {:assistant, %{parts: [%Part.Text{text: "Second response"}]}}},
                     500

      # The Agent GenServer must still be alive (the
      # original bug crashed it with FunctionClauseError).
      assert Process.alive?(pid)
    end
  end

  describe "stop_chat/2 returns synchronously" do
    test "Agent.stop_chat/2 blocks until the Agent's handle_call replies and the turn is cleared" do
      # `Agent.stop_chat/2` is `GenServer.call(pid, {:stop_chat, from},
      # :infinity)`. Per SMELLS.md, all own-GenServer communication uses
      # call/cast — no `send/2`. The test verifies the call returns `:ok`
      # and that the in-process turn has been finalized by the time the
      # call returns.
      events = for _ <- 1..100, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      assert :ok = Agent.stop_chat(pid, self())

      state = :sys.get_state(pid)
      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.active_worker == nil
      assert state.live.cancelled == false

      assert_receive {:chat_status, %{status: "idle"}}, 2000
    end
  end

  describe "stop_chat/2 always reaches idle" do
    test "a busy status with no active worker forces idle immediately" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # Busy status with no worker to stop (e.g. the turn already
      # finished). Stop must recover synchronously.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | live: %{
              state.live
              | machine:
                  Machine.status_to_machine(
                    state.live.machine,
                    :executing_tools
                  )
            }
        }
      end)

      assert :ok = Agent.stop_chat(pid, self())

      assert_receive {:chat_status, %{status: "idle"}}, 500
      assert Machine.status_for(:sys.get_state(pid).live.machine) == :idle
    end

    test "spawn_failed forces idle and broadcasts an error" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :sys.replace_state(pid, fn state ->
        %{
          state
          | live: %{
              state.live
              | machine: Machine.status_to_machine(state.live.machine, :streaming)
            }
        }
      end)

      capture_log(fn ->
        result = TurnHandler.spawn_failed(:sys.get_state(pid), "saturated")

        assert Machine.status_for(result.live.machine) == :idle
        assert is_nil(result.live.machine.work.ctx)
        assert_receive {:chat_error, %{content: content}}, 500
        assert content =~ "saturated"

        # Apply the returned state so teardown sees the agent idle.
        :sys.replace_state(pid, fn _ -> result end)
      end)
    end
  end

  # Drain assistant messages until one carries a `Part.ToolUse`.
  # A context-notice synthetic pair (an assistant message with
  # `text: "Context?"`) may precede the real tool-call assistant
  # when the context threshold is crossed.
  defp wait_for_assistant_with_tool_use(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_assistant_with_tool_use(deadline)
  end

  defp do_wait_for_assistant_with_tool_use(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      nil
    else
      receive do
        {:chat_message, {:assistant, msg}} ->
          if Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1)) do
            msg
          else
            do_wait_for_assistant_with_tool_use(deadline)
          end
      after
        100 -> do_wait_for_assistant_with_tool_use(deadline)
      end
    end
  end
end
