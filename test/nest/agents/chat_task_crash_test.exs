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
  use Nest.DataCase, async: true

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

        # Fence on idle: 500ms accounts for preflight BPE init
        # (Tiktoken CL100K count_tokens is a DirtyCpu NIF; the
        # first call on each of BEAM's 32 dirty CPU threads pays
        # a 200-325ms init cost). Once the fence passes, every
        # earlier message in the chat pipeline has already
        # arrived in the test's mailbox.
        assert_receive {:chat_status, %{status: "idle"}}, 500

        # The user message is broadcast first (the agent builds
        # it before the ChatTurn starts).
        assert_received {:chat_message, {:user, %{index: 1}}}

        # The ChatTurn catches the raise and sends
        # `{:chat_crashed, reason, stacktrace}` to the
        # Agent. The Agent's `chat_crashed/3` handler
        # broadcasts `chat:error` followed by a `chat:status:
        # idle` transition. The error message carries the
        # exception's text AND a stacktrace snippet (the user
        # explicitly asked for the file/line of the crash to
        # be visible so they can find it in the server log).
        assert_received {:chat_error, %{content: content}}
        assert content =~ "no function clause matching"
        assert content =~ "finish_event"
        # The source tag is appended so the user can grep the
        # server log for the matching `chat:error` entry.
        assert content =~ "[Source:"
        # The stacktrace snippet is included below the message.
        assert content =~ "** (FunctionClauseError)"

        # Regression: only ONE chat:error event should fire per
        # HTTP worker error. The HTTP worker's on_error callback
        # used to broadcast chat:error directly AND send
        # {:llm_error, msg} to the Agent, which would broadcast
        # again. Now the worker only sends the message; the
        # Agent is the single source. refute_receive can't be
        # converted to refute_received (which checks the current
        # mailbox snapshot), so it stays as a timed wait.
        refute_receive {:chat_error, _}, 500
      end)
    end

    test "the agent GenServer stays alive after the HTTP worker crashes", %{} do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

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
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

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

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")

        # Fence on idle (see comment in the test above for
        # the 500ms rationale — preflight + crash recovery
        # under concurrent test load).
        assert_receive {:chat_status, %{status: "idle"}}, 500

        # Wait for the user message first.
        assert_received {:chat_message, {:user, %{index: 1}}}

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
    end
  end

  describe "chat_crashed when the HTTP worker exits cleanly during test cleanup" do
    # AGENTS.md: "tests must not print to the console except
    # during debugging." A `GenServer.call/3` to the
    # MockClient's `Agent` exits with `{:normal, {GenServer,
    # :call, _}}` (or `{:noproc, _}` if the queue is already
    # gone) when `MockClient.stop/1` is called from `on_exit`
    # while the HTTP worker is mid-call. The HTTP worker's
    # `forward_crash/5` and the Agent's `chat_crashed/3`
    # both detect this pattern and silently transition to
    # `:idle` without logging or broadcasting `chat:error`.
    # Without the benign-exit filter, every test that
    # exercises a full compactor pipeline (or any test where
    # the chat turn is still running at test end) prints
    # `[agent_chat_turn] HTTP worker CRASHED` to the test
    # output.
    test "a {:normal, {GenServer, :call, _}} exit does NOT log or broadcast chat:error", %{} do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      Mimic.stub(MockClient, :run, fn _request, _opts ->
        # Simulate the MockClient's `Agent` exiting normally
        # mid-call. `GenServer.call(mock_client_pid, msg)` is
        # raising this in real test-cleanup scenarios.
        exit({:normal, {GenServer, :call, [self(), :get_and_update, 5000]}})
      end)

      Mimic.allow(MockClient, self(), pid)

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          # Wait for the silent shutdown to complete: the
          # Agent transitions to `:idle` without a `chat:error`
          # broadcast.
          assert_receive {:chat_status, %{status: "idle"}}, 500
        end)

      # `capture_log` captures logger output from any process
      # whose group leader is the test process — including
      # Tasks from previous tests that haven't fully shut
      # down. Filter to this test's agent_id so a leftover
      # log from a different agent doesn't trigger a false
      # positive.
      this_agent_log =
        log
        |> String.split("\n")
        |> Enum.filter(&agent_log?(&1, agent_id))
        |> Enum.join("\n")

      # The benign exit was silent — no error log for this agent.
      refute this_agent_log =~ "HTTP worker CRASHED"
      refute this_agent_log =~ "chat_crashed"

      # No `chat:error` was broadcast (the user-visible
      # error path is reserved for real failures).
      refute_receive {:chat_error, _}, 200

      # The agent finalized cleanly — still alive, in :idle.
      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      assert state.live.status == :idle
    end

    test "a {:noproc, {GenServer, :call, _}} exit (target already gone) is also silent", %{} do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      Mimic.stub(MockClient, :run, fn _request, _opts ->
        exit({:noproc, {GenServer, :call, [self(), :get_and_update, 5000]}})
      end)

      Mimic.allow(MockClient, self(), pid)

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")
          assert_receive {:chat_status, %{status: "idle"}}, 500
        end)

      this_agent_log =
        log
        |> String.split("\n")
        |> Enum.filter(&agent_log?(&1, agent_id))
        |> Enum.join("\n")

      refute this_agent_log =~ "HTTP worker CRASHED"
      refute this_agent_log =~ "chat_crashed"
      refute_receive {:chat_error, _}, 200
    end

    test "a bare :normal raise still surfaces (not silenced)", %{} do
      # Sanity check the filter: a `raise` or `:exit` whose
      # reason is bare `:normal` (no GenServer.call wrapper)
      # is still logged and broadcast. The benign-exit filter
      # is specifically for the GenServer.call shape so a
      # future exit that happens to be `:normal` doesn't get
      # swallowed silently.
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      Mimic.stub(MockClient, :run, fn _request, _opts ->
        # A bare :normal exit (no GenServer.call wrapping).
        exit(:normal)
      end)

      Mimic.allow(MockClient, self(), pid)

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          # Real crashes still surface — Agent transitions to
          # :idle after broadcasting chat:error.
          assert_receive {:chat_status, %{status: "idle"}}, 500
        end)

      # Filter to this test's agent (see comment in the
      # sibling test above for why a raw `log =~` is brittle).
      this_agent_log =
        log
        |> String.split("\n")
        |> Enum.filter(&agent_log?(&1, agent_id))
        |> Enum.join("\n")

      # The bare :normal exit was treated as a real crash.
      # (Note: the wrapped %RuntimeError{message: ":normal"}
      # string contains the substring ":normal" but not
      # "{GenServer, :call,", so `benign_chat_crash?/1`
      # returns false. The agent logs chat_crashed normally.)
      assert this_agent_log =~ "chat_crashed"
    end
  end

  # Logger output is captured test-process-wide. Match either
  # log format (`agent_id=...` in the HTTP worker log or
  # `[agent:...]` in the Agent's log) so a line clearly tied to
  # this test's agent is recognized regardless of which layer
  # emitted it.
  defp agent_log?(line, agent_id) do
    String.contains?(line, "agent_id=#{agent_id}") or
      String.contains?(line, "[agent:#{agent_id}]")
  end
end
