defmodule Nest.Agents.ChatTaskCrashTest do
  @moduledoc """
  Tests for the chat-turn crash-recovery flow.

  When the HTTP worker (running in `Task.Supervisor` under
  `Nest.Agents.TaskSupervisor`, spawned by the in-process turn)
  raises an unhandled exception (e.g. a `FunctionClauseError`
  because the LLM provider sent an unrecognized delta
  shape), `Turn.HTTPWorker.run/2`'s `try/catch` converts the raise
  into a `{:worker_crashed, ref, exception, stacktrace}` message to
  the Agent. The Agent routes it to the `{:worker_crashed, _}`
  transition, which then:

    1. Saves any partial content as a normal assistant
       message (so the user doesn't lose their work).
    2. Broadcasts a `chat:error` so the frontend's
       `StatusBanner` shows the error and `clearPartial/1`
       wipes the streaming partial.
    3. Broadcasts a `chat:status: idle` so the agent chip
       drops out of "Generating response...".
    4. Transitions the agent to `:idle`.

  Without this flow, the worker would die silently, the
  Agent would stay in `:streaming` status forever, and the
  UI would be stuck on "Generating response...".

  The crash boundary is the LLM client boundary
  (`Nest.LLM.MockClient.run/2` here). The stubs in this file
  target that boundary.

  The benign-exit (test-cleanup) variants live in
  `ChatTaskCleanupTest` so these flows run on their own worker.
  """
  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part

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
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      # Stub the LLM client (the new crash boundary) to
      # raise a `FunctionClauseError` — the same shape
      # the MiniMax field report exhibited. This runs in
      # the HTTP worker; the worker's try/catch converts
      # it into a `{:worker_crashed, ref, exception, stacktrace}`
      # message to the Agent.
      Mimic.stub(MockClient, :run, fn _request, _opts ->
        raise FunctionClauseError,
          module: Nest.LLM.OpenAIClient,
          function: :finish_event,
          arity: 1,
          args: [%{"delta" => %{"role" => "assistant"}}]
      end)

      Mimic.allow(MockClient, self(), pid)

      # The crash is reported to the server log (`Broadcasts.log_error/4` logs
      # the error before broadcasting the structured `chat:error` event) as
      # well as to the UI over PubSub; both are asserted below.
      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          # Fence on idle: 500ms is the project's standard fence for a whole
          # turn. This comment used to justify the value with a ~200-325ms BPE
          # vocabulary build paid once per dirty CPU scheduler thread; that
          # mechanism was DELETED when the project moved from `tiktoken` to
          # `tokenizers`, which builds the vocabulary once and shares it across
          # threads via `:persistent_term` (see `Nest.Tokens.Tokenizer`). Once
          # the fence passes, every earlier message in the chat pipeline has
          # already arrived in the test's mailbox.
          assert_receive {:chat_status, %{status: "idle"}}, 1_000

          # The worker catches the raise and sends
          # `{:worker_crashed, ref, exception, stacktrace}` to the
          # Agent. The Agent's `{:worker_crashed, _}` transition
          # broadcasts `chat:error` followed by a `chat:status:
          # idle` transition. The error message carries the
          # exception's text; the stacktrace snippet it also carries
          # is asserted by the snippet test below.
          assert_received {:chat_error, %{content: content}}
          assert content =~ "no function clause matching"
          # The source tag is appended so the user can grep the
          # server log for the matching `chat:error` entry.
          assert content =~ "[Source:"

          # Regression: only ONE chat:error event should fire per
          # HTTP worker error. The HTTP worker's on_error callback
          # used to broadcast chat:error directly AND send
          # {:llm_error, msg} to the Agent, which would broadcast
          # again. Now the worker only sends the message; the
          # Agent is the single source. The one error frame is
          # already in this mailbox (`assert_received` above), so
          # a second one would be too — `refute_received` is the
          # snapshot check, and it needs no wait at all.
          refute_received {:chat_error, _}
        end)

      assert log =~ "chat:error"
      assert log =~ "no function clause matching"
    end

    test "the user-facing message includes the file/line of the crash (stacktrace snippet)",
         %{} do
      # The user explicitly asked for "stuff to help pinpoint
      # where the error is happening". We now include a
      # multi-frame stacktrace snippet in the user-facing
      # error message so the user can see WHERE the crash
      # happened without grepping the server log.
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      Mimic.stub(MockClient, :run, fn _request, _opts ->
        # Raise from a known source so the stacktrace has a
        # stable frame to assert on.
        raise "unique_pin_marker_12345"
      end)

      Mimic.allow(MockClient, self(), pid)

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          assert_receive {:chat_error, %{content: content}}, 1_000

          # The original exception message is at the top.
          assert content =~ "unique_pin_marker_12345"
          # The stacktrace includes the test file (where the raise
          # originated) so the user can locate the crash frame
          # even when the actual production code has moved.
          assert content =~ "test/nest/agents/chat_task_crash_test.exs"
        end)

      # The same error reaches the server log, with the exception text in it.
      assert log =~ "chat:error"
      assert log =~ "unique_pin_marker_12345"
    end
  end

  describe "chat_crashed with partial content" do
    test "partial streaming content is saved as a normal assistant message before the error is broadcast",
         %{} do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

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

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          # Fence on idle (see comment in the test above for
          # the 500ms rationale — preflight + crash recovery
          # under concurrent test load).
          assert_receive {:chat_status, %{status: "idle"}}, 1_000

          # The partial content is saved as a normal assistant
          # message before the error is broadcast.
          assert_received {:chat_message,
                           {:assistant,
                            %Assistant{index: 2, parts: [%Part.Text{text: "Halfway through..."}]}}}

          # Then the error and idle status. The error content now
          # includes a stacktrace snippet (per the new format).
          assert_received {:chat_error, %{content: content}}
          assert content =~ "stream failed"
        end)

      assert log =~ "chat:error"
      assert log =~ "stream failed"
    end
  end

  describe "chat_crashed when the worker dies without reporting" do
    test "an abnormal worker exit is detected via monitor and the agent idles", %{} do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      parent = self()

      # Block the worker so the monitor is established while it is still
      # alive. A stub that exits immediately can lose the race against
      # `Process.monitor/1` and report `:noproc` instead of the real exit
      # reason; blocking makes the monitor-DOWN reason deterministic.
      Mimic.stub(MockClient, :run, fn _request, _opts ->
        send(parent, {self(), :worker_blocked})

        receive do
          :never -> :ok
        after
          # Safety valve: without this, a failure in either wait below leaves
          # this stub blocked forever under `TaskSupervisor` for the rest of
          # the run. Never fires on the passing path (the worker is killed
          # well before it).
          2_000 -> :ok
        end
      end)

      Mimic.allow(MockClient, self(), pid)

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          # The worker sends us its own pid, so there is nothing to poll: the agent
          # recorded `active_worker` before the worker could run, and a synchronous
          # read is ordered after that write.
          assert_receive {worker, :worker_blocked}, 1_000
          assert Agent.get_work(pid, 1_000).active_worker == worker

          # A raw exit signal (not trappable by the worker's own try/catch)
          # kills the worker before it can send a result. The turn's
          # `Process.monitor` DOWN must convert that into `chat_crashed`;
          # otherwise the turn hangs in `:streaming` forever.
          Process.exit(worker, :boom)

          assert_receive {:chat_status, %{status: "idle"}}, 1_000
          assert_received {:chat_error, %{content: content}}
          assert content =~ "boom"
        end)

      assert log =~ "chat_crashed"
      assert log =~ "chat:error"

      # allowlist: snapshot — status + work
      state = :sys.get_state(pid, 1_000)
      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.active_worker == nil
    end
  end

  describe "contentless provider response" do
    test "never persists an empty assistant message", %{} do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      MockClient.set_response("")

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          assert_receive {:chat_status, %{status: "idle"}}, 1000
          assert_received {:chat_error, %{content: content}}
          assert content =~ "no content"
        end)

      assert log =~ "chat:error"
      assert log =~ "The model returned a response with no content."

      messages = Agent.get_messages(pid, 1_000)

      # No message in the list is empty.
      refute Enum.any?(messages, fn
               {_role, %{parts: []}} -> true
               _ -> false
             end)

      # The turn still produced a non-empty assistant error message.
      assert Enum.any?(messages, fn
               {:assistant, %Assistant{parts: [_ | _]}} -> true
               _ -> false
             end)
    end
  end
end
