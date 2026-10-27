defmodule Nest.Spaces.ContextWarnings do
  @moduledoc """
  The one space setting that is **not** part of the sandbox environment:
  whether the runtime appends its 25/50/75% context-usage notices to this
  space's agents (`Nest.Agents.Agent.Turn.ContextReminder`).

  Off by default (issue #176). The notices exist to help an agent judge its own
  headroom, but one that arrives before compaction can also read as "stop now",
  which is the opposite of what the threshold means, so a space opts in.

  ## Why it is written on its own

  A workspace, a network access and a sandbox backend are one decision
  (`Nest.Spaces.update_environment/3`): they are part of a container's identity,
  a live agent's mounts are built from them, and an edit therefore stops work,
  releases the environment and tells every agent. None of that is true here.
  Nothing about this value reaches a command, so it is not on
  `Nest.Sandbox.Mounts`; a save stops nothing, releases nothing, and no notice is
  owed. Hence one column write, and no latch.

  ## When a change takes effect

  The value is read once, at agent start, into the agent's own state
  (`Nest.Spaces.environment/1` is where the row read happens) and from there into
  the machine's `ctx` (`Nest.Agents.Agent.Turn.build_ctx/2`). An agent that is
  already running keeps the value it started with — which is what the dialog
  tells the user, rather than leaving them to discover it.
  """

  alias Nest.Repo
  alias Nest.Spaces.Space

  @doc """
  Set `space`'s context-warnings flag, returning the row as it now stands.

  A value the row already holds writes nothing — `Ecto.Changeset.change/2`
  records no change for it, and `Repo.update/1` sends no query for an empty
  changeset — which is the same rule the environment edit relies on for a save
  that names what the row already says.
  """
  @spec set(Space.t(), boolean()) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def set(%Space{} = space, value) when is_boolean(value) do
    space
    |> Ecto.Changeset.change(context_warnings: value)
    |> Repo.update()
  end
end
