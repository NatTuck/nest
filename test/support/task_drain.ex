defmodule Nest.Test.TaskDrain do
  @moduledoc """
  Helper for draining pending LLM Tasks between tests.

  Agents spawn short-lived Tasks via `Task.Supervisor.start_child/2` for
  each chat message. A test that triggers a chat but doesn't wait for
  the LLM response can leave a Task running after the test ends. The
  Task would then make a real HTTP call (the Mimic stub is cleared on
  test exit) and crash with the test-only `ReqNullAdapter` error.

  Call `drain/1` from a test's `on_exit` to wait for all children of
  `Nest.Agents.TaskSupervisor` to finish before the next test starts.
  """

  @timeout_ms 10
  @interval_ms 10

  @doc """
  Waits up to #{@timeout_ms}ms for all children of
  `Nest.Agents.TaskSupervisor` to finish.

  Wrapped in `ExUnit.CaptureLog.capture_log/2` so any crash output from
  a leaked Task (e.g. the test-only `ReqNullAdapter` crash) is swallowed
  rather than polluting the test runner output.
  """
  def drain do
    ExUnit.CaptureLog.capture_log(fn -> do_drain() end)
    :ok
  end

  defp do_drain do
    deadline = System.monotonic_time(:millisecond) + @timeout_ms
    do_drain_loop(deadline)
  end

  defp do_drain_loop(deadline) do
    case Task.Supervisor.children(Nest.Agents.TaskSupervisor) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@interval_ms)
          do_drain_loop(deadline)
        else
          :ok
        end
    end
  end
end
