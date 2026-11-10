defmodule Nest.Agents.StartGuard do
  @moduledoc """
  The check that a start is still wanted, and the termination that makes a
  refusal true.

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
  """

  alias Nest.Agents.Registry
  alias Nest.Spaces

  @supervisor Nest.Agents.Supervisor

  @doc """
  A start's result, once the space has had its say.

  `{:ok, name}` becomes `{:error, :space_archived}` — with `name`'s process
  stopped — when its space is archived; every other result passes through
  untouched, so the caller's own refusals keep their reasons.
  """
  @spec verify({:ok, String.t()} | {:error, term()}, integer(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def verify({:ok, name}, space_id, name) do
    with :ok <- space_active(space_id, name), do: {:ok, name}
  end

  def verify(other, _space_id, _name), do: other

  @doc """
  Terminate `name`'s process through the supervisor, if it has one.

  Synchronous: the Registry name is free when this returns.
  """
  @spec terminate_child(integer(), String.t()) :: :ok | {:error, :not_found}
  def terminate_child(space_id, name) do
    case Registry.lookup(space_id, name) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(@supervisor, pid)
      {:error, :not_found} -> :ok
    end
  end

  defp space_active(space_id, name) do
    if Spaces.archived?(space_id) do
      terminate_child(space_id, name)
      {:error, :space_archived}
    else
      :ok
    end
  end
end
