defmodule Nest.Agents.Supervisor.PreSpawned do
  @moduledoc """
  The start wrapper for a row `Agent.pre_spawn/1` just inserted: run the start,
  enforce the spawning-only agent cap, and remove the row when no process
  started.

  Extracted from `Nest.Agents.Supervisor` (which is at its file-length cap) so
  the cap gate could be added without growing it. The supervisor delegates
  `start_pre_spawned/3` here; the spawn paths and `Nest.Agents.create_agent/3`
  reach it through that delegate.
  """

  require Logger

  alias Nest.Agents.StartGuard
  alias Nest.Persistence

  @doc """
  Run the start call for a row `Agent.pre_spawn/1` just inserted, removing
  that row when no process started.

  Every pre-spawn site has the same shape: insert the row (and its system
  message), then start the process. A start that does not happen leaves an
  orphan that also blocks every retry with the same name
  (`unique_constraint([:space_id, :name])`). `start` is the call that starts the
  agent — `fetch_or_start_agent/2` for a caller-created agent,
  `start_under_supervisor/2` for a spawn — and its `{:ok, name}` passes through
  the spawning-only cap (`StartGuard.within_agent_limit/2`).

  Anything else means no process exists for `attrs`:

    * an `{:error, reason}` return (a failed `init/1`, a `:not_found` race);
    * an exception raised on the way, e.g. inside `Agent.pre_load_heal/1`,
      which is why this is a `rescue` and not just a `case`. The exception
      is re-raised unchanged after the cleanup — it is the caller's failure
      to report, not ours to swallow.

  The delete is by `id`, never by name: this can only ever remove the row the
  caller inserted, and a concurrent caller's row would be a different `id`.
  Deleting also cascades to the messages the same `pre_spawn/1` wrote
  (`messages.agent_id` is `on_delete: :delete_all`).

  A start that reports `{:ok, name}` (including `:already_started`, which
  means some other caller's process owns the name) removes nothing — unless the
  cap refuses it, which stops the process and rolls the row back like any failed
  start. A rehydrate or restart never reaches here: it calls
  `fetch_or_start_agent/2` directly, so an over-cap space still loads its own
  agents.
  """
  @spec start_pre_spawned(map(), integer(), (-> {:ok, String.t()} | {:error, term()})) ::
          {:ok, String.t()} | {:error, term()}
  def start_pre_spawned(attrs, agent_id, start) when is_integer(agent_id) do
    start.()
  rescue
    exception ->
      rollback_pre_spawned(attrs, agent_id, exception)
      reraise exception, __STACKTRACE__
  else
    {:ok, name} ->
      # The cap gates spawning only; the check runs after the row exists
      # (race-safe), and on refusal it has stopped the process.
      case StartGuard.within_agent_limit(attrs.space_id, name) do
        :ok ->
          {:ok, name}

        {:error, reason} ->
          rollback_pre_spawned(attrs, agent_id, reason)
          {:error, reason}
      end

    {:error, reason} ->
      rollback_pre_spawned(attrs, agent_id, reason)
      {:error, reason}
  end

  defp rollback_pre_spawned(attrs, agent_id, reason) do
    Logger.warning(
      "Agent #{attrs.space_id}/#{attrs.name} (id #{agent_id}) failed to start " <>
        "(#{inspect(reason)}); removing the row it pre-spawned"
    )

    Persistence.delete_agent_by_id(agent_id)
  end
end
