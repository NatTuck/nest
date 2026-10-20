defmodule Nest.Sandbox.ShellJobs.Index do
  @moduledoc """
  How `Nest.Sandbox.ShellJobs` finds a job among the ones it tracks.

  Pure queries over the manager's state: a job by its owner's key, by its space,
  by the erlang pid running it, or by the OS pid its output arrives under — plus
  how many of an agent's jobs are running, which is the per-agent cap's count.
  The manager owns the state; this module owns nothing. Split out of
  `Nest.Sandbox.ShellJobs` for the file cap.

  Ownership is never widened here: `fetch/3` matches the whole
  `{space_id, agent_name}` key and `fetch_in_space/3` matches only its space
  half, so neither can reach a job in another space.
  """

  @doc "The job `job_id`, if `agent_key` owns it."
  @spec fetch(map(), term(), String.t()) :: {:ok, map()} | :error
  def fetch(state, agent_key, job_id) do
    case Map.get(state.jobs, job_id) do
      %{agent_key: ^agent_key} = job -> {:ok, job}
      _ -> :error
    end
  end

  @doc "The job `job_id`, if any agent in `space_id` owns it."
  @spec fetch_in_space(map(), term(), String.t()) :: {:ok, map()} | :error
  def fetch_in_space(state, space_id, job_id) do
    case Map.get(state.jobs, job_id) do
      %{agent_key: {^space_id, _}} = job -> {:ok, job}
      _ -> :error
    end
  end

  @doc "The job whose exec port is `pid`, if any."
  @spec by_erl_pid(map(), pid()) :: map() | nil
  def by_erl_pid(state, pid),
    do: Enum.find_value(state.jobs, fn {_id, j} -> j.erl_pid == pid && j end)

  @doc """
  The job streaming output from OS pid `os_pid`, if any.

  Prefer a running job with that pid; fall back to a finished one so trailing
  output still lands in its log. PID reuse across a running and a retained
  finished job can't misroute output this way.
  """
  @spec by_os_pid(map(), non_neg_integer()) :: map() | nil
  def by_os_pid(state, os_pid) do
    jobs = Enum.map(state.jobs, fn {_id, j} -> j end)

    Enum.find(jobs, fn j -> j.status == :running and j.os_pid == os_pid end) ||
      Enum.find(jobs, fn j -> j.os_pid == os_pid end)
  end

  @doc "The ownership key of the agent whose process is `pid`, if tracked."
  @spec agent_key_by_monitor(map(), pid()) :: term() | nil
  def agent_key_by_monitor(state, pid) do
    Enum.find_value(state.agents, fn {key, %{pid: p}} -> p == pid && key end)
  end

  @doc "How many of `agent_key`'s jobs are running — the per-agent cap's count."
  @spec running_count(map(), term()) :: non_neg_integer()
  def running_count(state, agent_key) do
    state.jobs
    |> Map.values()
    |> Enum.count(&(&1.agent_key == agent_key and &1.status == :running))
  end
end
