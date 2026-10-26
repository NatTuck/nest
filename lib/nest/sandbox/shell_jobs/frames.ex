defmodule Nest.Sandbox.ShellJobs.Frames do
  @moduledoc """
  The frames the job manager broadcasts about one agent's jobs.

  Split out of `Nest.Sandbox.ShellJobs` for the source-file cap, like `Waiters`
  and `ExitNotice`: the manager owns the state, this module owns what it says
  about it, and it reads that state the way `Index` does.

  One change to an agent's job set is two frames for two audiences:

    * `{:shell_jobs, %{jobs: [...]}}` on the agent's own topic
      (`Nest.Agents.Agent.Broadcasts.topic/2`), which the job panel renders.
    * `{:agent_jobs, %{space_id, name, count}}` on the space's topic (#175),
      which the sidebar's agent row renders as `name (count)`. It is a frame of
      its own rather than a field on the agent's status because starting or
      finishing a job does not change the agent's status, so no status frame
      would carry the news.

  Both are built from one `Info.t()` list, so the count the sidebar shows and
  the job list the panel shows are one read of the manager's state.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.PubSub
  alias Nest.Sandbox.ShellJobs.Info

  @doc """
  Broadcast `agent_key`'s jobs to both audiences.

  Returns `state` unchanged, so a caller can end a pipeline that mutated the job
  map in a broadcast (`state |> put_job(job) |> broadcast(agent_key)`).

  A key that names no agent — the tools' `{:unknown, :unknown}` fallback — has
  no topic to speak on and is a no-op.
  """
  @spec broadcast(map(), Nest.Sandbox.ShellJobs.agent_key()) :: map()
  def broadcast(%{jobs: jobs} = state, {space_id, name})
      when is_integer(space_id) and is_binary(name) do
    info =
      jobs
      |> Map.values()
      |> Enum.filter(&(&1.agent_key == {space_id, name}))
      |> Enum.map(&Info.to_info/1)

    Phoenix.PubSub.broadcast(
      PubSub,
      Broadcasts.topic(space_id, name),
      {:shell_jobs, %{jobs: info}}
    )

    Phoenix.PubSub.broadcast(
      PubSub,
      Broadcasts.space_topic(space_id),
      {:agent_jobs, %{space_id: space_id, name: name, count: Info.running_count(info)}}
    )

    state
  end

  def broadcast(state, _agent_key), do: state
end
