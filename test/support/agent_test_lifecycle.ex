defmodule Nest.Agents.AgentTestLifecycle do
  @moduledoc """
  Lifecycle helpers for the agent test suite — separate
  from `AgentTestHelpers` so the test support file stays
  under the credo 500-line cap.

  Currently exposes `wait_for_pid_down/3`, the single-message
  :DOWN wait used by `AgentTestHelpers` to synchronize
  GenServer shutdown before the test exits its sandbox
  checkout. (Drain loops are explicitly forbidden here —
  see the impl for the rationale.)
  """

  @doc """
  Send `:shutdown` to the agent pid and wait for its
  `:DOWN` (single-message receive, not a drain loop).
  No-op if the pid is already gone. Public so tests can
  call it directly without re-implementing the pattern.

  `Process.monitor/1` registers the DOWN subscription
  before `Process.exit/2` so the receive can't miss the
  event even if the pid was already dead at monitor-time
  (returns `:DOWN, :noproc`). `Process.demonitor/1, [:flush]`
  on timeout cleans up any pending DOWN. Default 100ms
  matches the project standard for `assert_receive`; the
  agent's `terminate/2` is filesystem-only and completes
  well within this window.
  """
  @spec wait_for_pid_down(integer(), String.t(), pos_integer()) :: :ok
  def wait_for_pid_down(space_id, name, timeout \\ 100) do
    case Nest.Agents.Registry.lookup(space_id, name) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            :ok
        end

      _ ->
        :ok
    end
  end
end
