defmodule Nest.Sandbox.ShellJobs.Frames do
  @moduledoc """
  The frames the job manager broadcasts about one agent's jobs — and, on the
  space's topic, about every agent's jobs in that space.

  Split out of `Nest.Sandbox.ShellJobs` for the source-file cap, like `Waiters`
  and `ExitNotice`: the manager owns the state, this module owns what it says
  about it, and it reads that state the way `Index` does.

  One change to an agent's job set is three frames for two audiences:

    * `{:shell_jobs, %{jobs: [...]}}` on the agent's own topic
      (`Nest.Agents.Agent.Broadcasts.topic/2`), which the job panel renders.
    * `{:agent_jobs, %{space_id, name, count}}` on the space's topic (#175),
      which the sidebar's agent row renders as `name (count)`. It is a frame of
      its own rather than a field on the agent's status because starting or
      finishing a job does not change the agent's status, so no status frame
      would carry the news.
    * `{:space_jobs, %{space_id, jobs: [...]}}` on the space's topic (#225),
      the space-wide list every agent's jobs appear in — the lobby's space job
      panel renders it. It rides the same broadcast, so a job dying with its
      namespace holder (#224) reaches the space view exactly as it reaches the
      owner's panel: the reconciliation finishes the job, and the finish
      broadcasts.

  All three are built from one read of the manager's state, so the count the
  sidebar shows, the job list the panel shows and the space-wide list cannot
  disagree about what is running.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.PubSub
  alias Nest.Sandbox.ShellJobs.Info

  @doc """
  Broadcast `agent_key`'s jobs to both audiences.

  Returns `state` unchanged, so a caller can end a pipeline that mutated the job
  map in a broadcast (`state |> put_job(job) |> broadcast(agent_key)`).

  A key whose space is not an integer — the shell-jobs tests' `{:test, name}` —
  has no PubSub topic to speak on, and is a no-op.
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

    broadcast_space_jobs(jobs, space_id)

    state
  end

  def broadcast(state, _agent_key), do: state

  # The space-wide list (#225), ordered like `ShellJobs.list_space/1` so a
  # broadcast and a refresh read render the same rows in the same order.
  defp broadcast_space_jobs(jobs, space_id) do
    space_info = Info.list(jobs, &match?({^space_id, _}, &1.agent_key))

    Phoenix.PubSub.broadcast(
      PubSub,
      Broadcasts.space_topic(space_id),
      {:space_jobs, %{space_id: space_id, jobs: space_info}}
    )
  end
end
