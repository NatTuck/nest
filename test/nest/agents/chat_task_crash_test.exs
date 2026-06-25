defmodule Nest.Agents.ChatTaskCrashTest do
  @moduledoc """
  Tests for the ChatTurn crash-recovery flow.

  When the HTTP worker (running in `Task.Supervisor` under
  `Nest.Agents.TaskSupervisor`, spawned by the ChatTurn)
  raises an unhandled exception (e.g. a `FunctionClauseError`
  because the LLM provider sent an unrecognized delta
  shape), the ChatTurn's `try/catch` in
  `ChatTurn.http_worker_fun/2` converts the raise into a
  `{:chat_crashed, reason, stacktrace}` message to the
  Agent. The Agent's `LLMStreamHandler.chat_crashed/3`
  then:

    1. Saves any partial content as a normal assistant
       message (so the user doesn't lose their work).
    2. Broadcasts a `chat:error` so the frontend's
       `StatusBanner` shows the error and `clearPartial/1`
       wipes the streaming partial.
    3. Broadcasts a `chat:status: idle` so the agent chip
       drops out of "Generating response...".
    4. Transitions the agent to `:idle`.

  Without this flow, the ChatTurn would die silently, the
  Agent would stay in `:streaming` status forever, and the
  UI would be stuck on "Generating response...".

  After the ChatTurn refactor, the crash boundary moves
  from `Nest.Agents.Agent.LLMRunner.run/2` to
  `Nest.LLM.MockClient.run/2` (the new HTTP client
  boundary). The stubs in this file target the new
  boundary.
  """
  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "chat_crashed when the HTTP worker raises" do
    test "an unhandled FunctionClauseError is caught and the agent transitions to idle", %{} do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # Stub the LLM client (the new crash boundary) to
      # raise a `FunctionClauseError` — the same shape
      # the MiniMax field report exhibited. This runs in
      # the HTTP worker; the worker's try/catch converts
      # it into a `{:http_error, _}` to the ChatTurn,
      # which forwards `{:chat_crashed, reason, _}` to
      # the Agent.
      Mimic.stub(MockClient, :run, fn _request, _opts ->
        raise FunctionClauseError,
          module: Nest.LLM.OpenAIClient,
          function: :finish_event,
          arity: 1,
          args: [%{"delta" => %{"role" => "assistant"}}]
      end)

      Mimic.allow(MockClient, self(), pid)

      # capture_log swallows the `Logger.error` calls in
      # `Broadcasts.log_error/4` (the agent logs the error
      # before broadcasting the structured `chat:error`
      # event). The structured broadcast itself still
      # arrives on PubSub; the assertions below cover it.
      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")

        # The user message is broadcast first (the agent builds
        # it before the ChatTurn starts).
        assert_receive {:chat_message, {:user, %{index: 1}}}, 200

        # The ChatTurn catches the raise and sends
        # `{:chat_crashed, reason, stacktrace}` to the
        # Agent. The Agent's `chat_crashed/3` handler
        # broadcasts `chat:error` followed by a `chat:status:
        # idle` transition. The error message carries the
        # exception's text AND a stacktrace snippet (the user
        # explicitly asked for the file/line of the crash to
        # be visible so they can find it in the server log).
        assert_receive {:chat_error, %{content: content}}, 500
        assert content =~ "no function clause matching"
        assert content =~ "finish_event"
        # The source tag is appended so the user can grep the
        # server log for the matching `chat:error` entry.
        assert content =~ "[Source:"
        # The stacktrace snippet is included below the message.
        assert content =~ "** (FunctionClauseError)"

        assert_receive {:chat_status, %{status: "idle"}}, 200

        # Regression: only ONE chat:error event should fire per
        # HTTP worker error. The HTTP worker's on_error callback
        # used to broadcast chat:error directly AND send
        # {:llm_error, msg} to the Agent, which would broadcast
        # again. Now the worker only sends the message; the
        # Agent is the single source.
        refute_receive {:chat_error, _}, 100
      end)
    end

    test "the agent GenServer stays alive after the HTTP worker crashes", %{} do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      Mimic.stub(MockClient, :run, fn _request, _opts ->
        raise "boom"
      end)

      Mimic.allow(MockClient, self(), pid)

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")

        # Wait for the crash-recovery flow to complete. The
        # Agent's `chat_crashed/3` handler broadcasts
        # `chat:status: idle` after finalizing the partial
        # and transitioning out of `:streaming`.
        assert_receive {:chat_status, %{status: "idle"}}, 2000
      end)

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

      Mimic.stub(MockClient, :run, fn _request, _opts ->
        # Raise from a known source so the stacktrace has a
        # stable frame to assert on.
        raise "unique_pin_marker_12345"
      end)

      Mimic.allow(MockClient, self(), pid)

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")

        assert_receive {:chat_error, %{content: content}}, 500

        # The original exception message is at the top.
        assert content =~ "unique_pin_marker_12345"
        # The stacktrace includes the test file (where the raise
        # originated) so the user can locate the crash frame
        # even when the actual production code has moved.
        assert content =~ "test/nest/agents/chat_task_crash_test.exs"
      end)
    end
  end

  describe "chat_crashed with partial content" do
    test "partial streaming content is saved as a normal assistant message before the error is broadcast",
         %{} do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # Simulate the crash happening *after* some content was
      # streamed. The HTTP worker's streaming callback
      # normally populates the Agent's `streaming_acc` with
      # the deltas as they arrive; we simulate that by
      # directly sending a `delta_received` event to the
      # Agent from inside the stub before raising. The
      # Agent's `delta_received` handler updates the
      # mirror, and `chat_crashed`'s `finalize_partial_if_any`
      # reads it back to build the partial message.
      Mimic.stub(MockClient, :run, fn _request, _opts ->
        send(pid, {:delta_received, "Halfway through...", :text})
        raise "stream failed"
      end)

      Mimic.allow(MockClient, self(), pid)

      capture_log(fn ->
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
      end)
    end
  end
end
