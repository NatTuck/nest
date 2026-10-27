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

  alias Nest.Sandbox.ShellJobs

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

  @doc """
  The **running** job whose tool worker is monitored by `ref`, if any (#174).

  By ref rather than by pid: the ref is unique per registration, so a `:DOWN` for
  a *finished* foreground call's worker — one whose job a kill's fallback already
  ended — cannot match a later job's owner.
  """
  @spec by_owner_ref(map(), reference()) :: map() | nil
  def by_owner_ref(state, ref) do
    Enum.find_value(state.jobs, fn {_id, j} ->
      (j.status == :running and j.owner_ref == ref) && j
    end)
  end

  @doc """
  The **running** job whose exec port is `pid`, if any.

  Running only, because the one caller is the manager's `:DOWN` handler, whose
  job is to finish a job. `finish_job/3` leaves `erl_pid` in place, so without
  this a job already finished by the `{:kill_finalize, …}` fallback would be
  finished a second time by the port's late `:DOWN` — a second `shell:jobs`
  frame, and (issue #163) a second notice to the owner, which is a second turn
  on the same result.
  """
  @spec by_erl_pid(map(), pid()) :: map() | nil
  def by_erl_pid(state, pid),
    do:
      Enum.find_value(state.jobs, fn {_id, j} ->
        (j.status == :running and j.erl_pid == pid) && j
      end)

  @doc """
  The state of `job_id` as a waiter leaving it should see it.

  A waiter that gave up cannot tell whether the exit landed in the window
  between its own timeout and its `unsubscribe/3` being handled, so this is the
  one answer it gets — never a guess, and never a state the manager invented.

  `:gone` and `:trimmed` are both "the manager no longer tracks this job", and
  the difference is *why*, because the two mean different things to the caller:
  a job dropped with its agent is gone for good, while one evicted by retention
  (`trim/2` keeps the newest `@max_finished_per_agent`) exited normally and only
  its exit code went with the record. The agent record is what tells them
  apart: retention never removes it, and `drop_agent/3` removes both in one
  callback.

  The one thing it cannot tell is an evicted record from an id the manager never
  had; both answer `:trimmed` while the agent is tracked. No caller passes an id
  it did not get from `start_job/1`, so that is a limit on the answer rather
  than a case to handle.
  """
  @spec state(map(), ShellJobs.agent_key(), String.t()) ::
          :running | {:exited, integer()} | :trimmed | :gone
  def state(state, agent_key, job_id) do
    case Map.get(state.jobs, job_id) do
      %{status: {:exited, code}} -> {:exited, code}
      %{status: :running} -> :running
      _untracked -> if Map.has_key?(state.agents, agent_key), do: :trimmed, else: :gone
    end
  end

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

  @doc """
  How many of `agent_key`'s jobs the manager is running — the per-agent cap's
  count.

  Only the jobs this manager started count. A foreground `shell-cmd` call is a
  job too (#174), but it is not a background job: it must neither be refused by
  `caps.shell.background` nor take one of its slots, so it is not counted.
  """
  @spec running_count(map(), term()) :: non_neg_integer()
  def running_count(state, agent_key) do
    state.jobs
    |> Map.values()
    |> Enum.count(&(&1.agent_key == agent_key and &1.status == :running and &1.owner == nil))
  end
end
