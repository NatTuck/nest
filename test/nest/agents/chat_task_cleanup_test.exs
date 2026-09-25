defmodule Nest.Agents.ChatTaskCleanupTest do
  @moduledoc """
  Benign-exit filter tests: when the HTTP worker's `GenServer.call/3`
  target shuts down during test cleanup, the worker and the Agent must
  treat it as a silent `:idle` transition rather than a `chat:error`.

  Split from `ChatTaskCrashTest` so these full-chat flows run on their
  own ExUnit worker.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

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
