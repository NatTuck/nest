defmodule Nest.Agents.ChatTaskCrashTest do
  @moduledoc """
  Tests for the chat task crash-recovery flow.

  When the chat task (running in `Task.Supervisor` under
  `Nest.Agents.TaskSupervisor`) raises an unhandled exception
  (e.g. a `FunctionClauseError` because the LLM provider sent
  an unrecognized delta shape), the task's try/catch in
  `ChatPipeline.run_chat_task_and_notify/3` converts the
  raise into a `{:chat_task_crashed, msg}` message to the
  agent. The agent's `LLMStreamHandler.chat_task_crashed/2`
  then:

    1. Saves any partial content as a normal assistant
       message (so the user doesn't lose their work).
    2. Broadcasts a `chat:error` so the frontend's
       `StatusBanner` shows the error and `clearPartial/1`
       wipes the streaming partial.
    3. Broadcasts a `chat:status: idle` so the agent chip
       drops out of "Generating response...".
    4. Transitions the agent to `:idle`.

  Without this flow, the chat task would die silently, the
  agent would stay in `:streaming` status forever, and the UI
  would be stuck on "Generating response...".
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

  describe "chat_task_crashed when the LLM runner raises" do
    test "an unhandled FunctionClauseError is caught and the agent transitions to idle", %{} do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # Stub the LLM runner to raise a `FunctionClauseError` —
      # the same shape the MiniMax field report exhibited.
      # This runs in the chat task; the task's try/catch
      # converts it into a `{:chat_task_crashed, exception,
      # stacktrace}` to the agent.
      Mimic.stub(Nest.Agents.Agent.LLMRunner, :run, fn _ctx, _state ->
        raise FunctionClauseError,
          module: Nest.LLM.OpenAIClient,
          function: :finish_event,
          arity: 1,
          args: [%{"delta" => %{"role" => "assistant"}}]
      end)

      Mimic.allow(Nest.Agents.Agent.LLMRunner, self(), pid)

      :ok = Agent.chat(pid, "Hello")

      # The user message is broadcast first (the agent builds
      # it before the chat task runs).
      assert_receive {:chat_message, {:user, %{index: 1}}}, 200

      # The agent receives the chat_task_crashed notification
      # and broadcasts a chat:error followed by a status: idle
      # transition. The error message now carries the
      # exception's text AND a stacktrace snippet (the user
      # explicitly asked for the file/line of the crash to be
      # visible so they can find it in the server log).
      assert_receive {:chat_error, %{content: content}}, 500
      assert content =~ "no function clause matching"
      assert content =~ "finish_event"
      # The source tag is appended so the user can grep the
      # server log for the matching `chat:error` entry.
      assert content =~ "[Source:"
      # The stacktrace snippet is included below the message —
      # `Exception.format/3` leads with `** (FunctionClauseError)`,
      # and the snippet includes the chat_pipeline.ex line that
      # raised.
      assert content =~ "** (FunctionClauseError)"
      assert content =~ "chat_pipeline.ex"

      assert_receive {:chat_status, %{status: "idle"}}, 200
    end

    test "the agent GenServer stays alive after the chat task crashes", %{} do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      Mimic.stub(Nest.Agents.Agent.LLMRunner, :run, fn _ctx, _state ->
        raise "boom"
      end)

      Mimic.allow(Nest.Agents.Agent.LLMRunner, self(), pid)

      :ok = Agent.chat(pid, "Hello")

      # Wait for the agent to settle (broadcast happens, then
      # the agent goes idle).
      Process.sleep(100)

      # The agent is still alive and queryable.
      assert Process.alive?(pid)
      assert {:ok, _info} = Agent.get_public_info(pid) |> then(&{:ok, &1})
    end

    test "the user-facing message includes the file/line of the crash (stacktrace snippet)",
         %{} do
      # The user explicitly asked for "stuff to help pinpoint
      # where the error is happening". We now include a
      # multi-frame stacktrace snippet in the user-facing
      # error message so the user can see WHERE the crash
      # happened without grepping the server log.
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      Mimic.stub(Nest.Agents.Agent.LLMRunner, :run, fn _ctx, _state ->
        # Raise from a known source so the stacktrace has a
        # stable frame to assert on.
        raise "unique_pin_marker_12345"
      end)

      Mimic.allow(Nest.Agents.Agent.LLMRunner, self(), pid)

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_error, %{content: content}}, 500

      # The original exception message is at the top.
      assert content =~ "unique_pin_marker_12345"
      # The stacktrace includes the test file (where the raise
      # originated) so the user can locate the crash frame
      # even when the actual production code has moved.
      assert content =~ "test/nest/agents/chat_task_crash_test.exs"
    end
  end

  describe "chat_task_crashed with partial content" do
    test "partial streaming content is saved as a normal assistant message before the error is broadcast",
         %{} do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # Simulate the crash happening *after* some content was
      # streamed. The LLM runner's `LLMRunner.handle_new_stream/3`
      # normally populates `state.chat_state.streaming_acc` with
      # the deltas as they arrive; we simulate that by directly
      # appending to the streaming accumulator via the
      # delta_received event before the runner raises.
      #
      # We can't easily intercept at the delta level (the
      # MockClient's stream is synchronous), so instead we use
      # a stub that:
      #   1. Sends a delta_received event to the agent (so the
      #      streaming accumulator has some text).
      #   2. Raises.
      Mimic.stub(Nest.Agents.Agent.LLMRunner, :run, fn _ctx, _state ->
        send(pid, {:delta_received, "Halfway through...", :text})
        raise "stream failed"
      end)

      Mimic.allow(Nest.Agents.Agent.LLMRunner, self(), pid)

      :ok = Agent.chat(pid, "Hello")

      # Wait for the user message first.
      assert_receive {:chat_message, {:user, %{index: 1}}}, 200

      # The partial content is saved as a normal assistant
      # message before the error is broadcast.
      assert_receive {:chat_message,
                      {:assistant, %Assistant{index: 2, content: "Halfway through..."}}},
                     200

      # Then the error and idle status. The error content now
      # includes a stacktrace snippet (per the new format).
      assert_receive {:chat_error, %{content: content}}, 200
      assert content =~ "stream failed"
      assert_receive {:chat_status, %{status: "idle"}}, 200
    end
  end
end
