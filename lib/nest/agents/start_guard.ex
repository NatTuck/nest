defmodule Nest.Agents.StartGuard do
  @moduledoc """
  The check that a start is still wanted, and the termination that makes a
  refusal true.

  Both production start routes run it as their last step:
  `Nest.Agents.Supervisor.fetch_or_start_agent/2` (a caller-created agent, a
  rehydrate, a restart) and `Nest.Agents.Supervisor.start_pre_spawned_child/3`
  (a clone or a fresh sub-agent). `start_under_test/2` is the test-only route
  and does not.

  ## Why the check is *after* the start

  A space can be archived while a start is in flight, and a caller's own check
  cannot close that: the lobby's `spawn_agent` reads the space row before
  `Nest.Agents.Agent.PreSpawn.pre_spawn/1` renders a system prompt and writes it,
  so the archive can land in between. So
  `Nest.Agents.Supervisor.fetch_or_start_agent/2` runs this **after** the process
  exists — the one ordering that covers both halves, because
  `Nest.Spaces.archive_space/1` sets the flag *before* it sweeps the space's
  agent rows:

    * a row inserted before the flag went up is in the sweep's read, so the
      sweep stops its process — or this does, if the process started after it;
    * a row inserted after the flag went up is refused here, and a create path's
      caller rolls the row back (`Nest.Agents.Supervisor.start_pre_spawned/3`).

  ## Why the termination goes through the supervisor

  `Nest.Agents.Supervisor.stop_agent/2` fires `Process.exit/2` and returns before
  the process is gone, so a refusal built on it could answer "there is no agent"
  while one is still registered. `terminate_child/2` terminates through the
  `DynamicSupervisor`, which frees the Registry name before it returns — the same
  reason `Supervisor.restart_agent/2` uses it.

  ## The agent limit

  The same last step enforces the space's cap on **non-archived** agents — its
  blueprint's `max_agents`, or `default_max_agents/0` when the blueprint names
  none (or the space has no blueprint). The count is of *rows*, not processes:
  an idle agent is still on the team, and counting live pids would let a space
  of stopped agents grow without bound.

  It runs after the start for the same reason the archive check does, and the
  row ordering is what makes it race-safe: a create's row is inserted before
  its process starts, so it is visible to every concurrent start's count. Two
  spawns racing into the last free slot each count their own row; if the total
  is over the cap, every start that sees that refuses and its caller rolls the
  row back (`Nest.Agents.Supervisor.start_pre_spawned/3`). Two concurrent
  spawns may therefore *both* refuse where one could have been admitted — the
  safe direction, and the same conservatism as the archive sweep.

  A rehydrate or restart adds no row, so a space at its cap still starts its
  own agents. A space *over* a cap that was lowered afterwards cannot start
  any until some are archived — the gate reads the cap as it is now.
  """

  alias Nest.Agents.Registry
  alias Nest.Persistence
  alias Nest.Spaces

  @supervisor Nest.Agents.Supervisor

  # The cap a space gets when its blueprint names none. A named constant here
  # rather than a value copied into every blueprint row: `nil` in the column
  # means "no opinion", and the default is the gate's to state — one place to
  # change it, and nothing to backfill.
  @default_max_agents 5

  @doc """
  The agent cap a space gets when its blueprint names none (or it has no
  blueprint): the whole team, running or idle, archived rows excluded.
  """
  @spec default_max_agents() :: pos_integer()
  def default_max_agents, do: @default_max_agents

  @doc """
  A start's result, once the space has had its say.

  `{:ok, name}` becomes `{:error, :space_archived}` — with `name`'s process
  stopped — when its space is archived, or `{:error, {:agent_limit, limit}}`
  when the start would put the space over its agent cap; every other result
  passes through untouched, so the caller's own refusals keep their reasons.
  """
  @spec verify({:ok, String.t()} | {:error, term()}, integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def verify({:ok, name}, space_id, name) do
    with :ok <- space_active(space_id, name),
         :ok <- within_agent_limit(space_id, name),
         do: {:ok, name}
  end

  # A start that already failed keeps its own reason, and a `{:ok, other_name}`
  # cannot come out of `start_under_supervisor/2` — it returns the name it was
  # given — so neither has a space to verify against.
  def verify(other, _space_id, _name), do: other

  @doc """
  Terminate `name`'s process through the supervisor, if it has one.

  Synchronous, and `:ok` even when there was nothing to terminate: a name with
  no process, or a child that died between the lookup and the call, is already
  the outcome asked for. The name is free when this returns — the agent releases
  its Registry key in `terminate/2`, before the process exits.
  """
  @spec terminate_child(integer(), String.t()) :: :ok
  def terminate_child(space_id, name) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} ->
        # A child that died between the lookup and this call is already gone.
        _ = DynamicSupervisor.terminate_child(@supervisor, pid)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp space_active(space_id, name) do
    if Spaces.archived?(space_id) do
      # The refusal is only true if the process is really gone, so this is not a
      # fire-and-forget: `terminate_child/2` is synchronous and total.
      :ok = terminate_child(space_id, name)
      {:error, :space_archived}
    else
      :ok
    end
  end

  # The just-started agent's row is already in the count (a create inserts it
  # before the process exists), so "over the cap" is `>`, not `>=`: a space at
  # its cap rehydrating one of its own agents adds no row and passes.
  defp within_agent_limit(space_id, name) do
    limit = Spaces.max_agents_for_space(space_id) || @default_max_agents

    if Persistence.count_active_agents(space_id) > limit do
      :ok = terminate_child(space_id, name)
      {:error, {:agent_limit, limit}}
    else
      :ok
    end
  end
end
