defmodule Nest.Agents.AgentStopTest do
  @moduledoc """
  Tests for the user-initiated chat-stop flow. Covers:

    * Stopping mid-LLM-stream — partial assistant text is
      finalized into a message tagged with
      `metadata.stopped_by_user: true` and the agent
      transitions to `:idle`.
    * Stopping after the LLM stream completes (between turns)
      — no-op.
    * Stopping during a `context` tool compaction call — chat
      task unwinds, no `:compaction_done` chat_continuation
      auto-resumes.
    * Idempotency — multiple `Agent.stop_chat/2` calls
      before finalization don't crash anything.
  """
  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Test.TaskDrain

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    on_exit(fn -> TaskDrain.drain() end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "stop_chat/2 mid-LLM-stream" do
    test "finalizes the partial assistant message and transitions to idle" do
      events = for _ <- 1..1000, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, %{index: 0}}}, 100
      assert_receive {:chat_status, %{status: "streaming"}}, 100
      assert_receive {:chat_delta, _}, 100

      chat_task_pid = :sys.get_state(pid).chat_state.chat_task_pid
      assert is_pid(chat_task_pid)
      send(chat_task_pid, {:stop_chat, self()})

      assert_receive {:chat_message,
                      {:assistant, %Assistant{metadata: %{"stopped_by_user" => true}}}},
                     2000

      assert_receive {:chat_status, %{status: "idle"}}, 2000
    end

    test "the finalized assistant message carries the partial text content" do
      events = for _ <- 1..1000, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Tell me a story")
      assert_receive {:chat_message, {:user, _}}, 100
      assert_receive {:chat_delta, _}, 100

      chat_task_pid = :sys.get_state(pid).chat_state.chat_task_pid
      assert is_pid(chat_task_pid)
      send(chat_task_pid, {:stop_chat, self()})

      assert_receive {:chat_message, {:assistant, %Assistant{content: content, index: 1}}},
                     2000

      assert is_binary(content)
      assert content != ""
      assert String.starts_with?(content, "x")
    end
  end

  describe "stop_chat/2 between turns" do
    test "is a no-op when the agent is idle" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # No chat turn is in flight. The stop handler runs
      # without crashing; no `chat:status: idle` is broadcast
      # because the agent is already idle.
      :ok = Agent.stop_chat(pid, self())

      # Give the (no-op) handler a chance to run.
      Process.sleep(20)
      refute_receive {:chat_status, _}, 50
    end
  end

  describe "stop_chat/2 during context tool (compact action)" do
    test "the tool-call mid-execution stop unwinds without auto-resume" do
      # Set up a stream that emits one `context` tool call
      # with `action: "compact"`. The chat task enters
      # `request_compaction_from_task` which blocks on a
      # receive. We stop the chat task while it's blocked there.
      MockClient.set_tool_response(%{
        text: "compacting",
        tool_calls: [
          %{
            id: "call_1",
            name: "context",
            arguments: %{"action" => "compact", "focus" => "recent"}
          }
        ]
      })

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "compact please")

      assert_receive {:chat_message, {:user, _}}, 100
      # The tool call message is broadcast; the chat task
      # is now in `request_compaction_from_task` blocking on
      # `{:task_compaction_done|_failed, _}` or `{:stop_chat, _}`.
      assert_receive {:chat_message, {:assistant, %{tool_calls: [_]}}}, 500
      assert_receive {:chat_status, %{status: "executing_tools"}}, 500

      # The chat task is now in the blocking receive inside
      # `request_compaction_from_task/2`. Send the stop
      # directly to the chat task pid (avoids the GenServer
      # mailbox-ordering race).
      chat_task_pid = :sys.get_state(pid).chat_state.chat_task_pid
      assert is_pid(chat_task_pid)
      send(chat_task_pid, {:stop_chat, self()})

      # The agent's stop handler waits for the chat task to
      # ack via `{:chat_stopped, _}`. The tool loop's
      # `request_compaction_from_task/2` catches the
      # `{:stop_chat, _}`, replies `:stopped`, and the
      # tool executor raises `ToolLoop.StoppedError`, which
      # the chat task body catches and turns into the
      # `{:chat_stopped, self()}` ack.
      assert_receive {:chat_status, %{status: "idle"}}, 2000
    end
  end

  describe "stop_chat/2 idempotency" do
    test "multiple stop clicks don't crash the agent" do
      events = for _ <- 1..100, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, _}}, 100
      assert_receive {:chat_delta, _}, 100

      # Three rapid stops directly to the chat task. The
      # first sets the stream to halt; the second and third
      # are picked up by no receive (the consumer has already
      # halted) so they're no-ops.
      chat_task_pid = :sys.get_state(pid).chat_state.chat_task_pid

      send(chat_task_pid, {:stop_chat, self()})
      send(chat_task_pid, {:stop_chat, self()})
      send(chat_task_pid, {:stop_chat, self()})

      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # After the stop, the agent is in a clean state. A new
      # chat turn should work normally.
      :ok = Agent.chat(pid, "After the stop")

      assert_receive {:chat_message, {:user, %{index: 2}}}, 2000
      assert_receive {:chat_message, {:assistant, _}}, 2000
    end
  end

  describe "stop_chat/2 then a new chat turn" do
    test "the cancelled flag is cleared so the next pre-flight compaction can resume" do
      # First turn: stream a long-ish text response that we'll
      # stop mid-stream.
      events = for _ <- 1..100, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "First turn")
      assert_receive {:chat_message, {:user, _}}, 100
      assert_receive {:chat_delta, _}, 100

      # Send the stop directly to the chat task pid (avoids
      # the GenServer mailbox-ordering race).
      chat_task_pid = :sys.get_state(pid).chat_state.chat_task_pid
      send(chat_task_pid, {:stop_chat, self()})
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # The `cancelled` flag must be cleared on the next turn,
      # otherwise a pre-flight compaction's `chat_continuation`
      # would be discarded (see the guard in
      # `CompactionHandler.compaction_done/3`).

      # Second turn: a normal text response.
      MockClient.set_response("Second turn response")

      :ok = Agent.chat(pid, "Second turn")

      assert_receive {:chat_message, {:user, %{index: 2}}}, 2000
      assert_receive {:chat_message, {:assistant, %{content: "Second turn response"}}}, 2000
      assert_receive {:chat_status, %{status: "idle"}}, 2000
    end
  end
end
