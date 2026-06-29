defmodule Nest.Agents.Agent.Persistence do
  @moduledoc """
  Agent-side glue around `Nest.Persistence`.

  The persistence functions are gated on the runtime
  `:persistence_enabled` config flag (see `config/test.exs`).
  In test envs the flag is `false` so the writes are
  no-ops — the live in-memory state remains the source of
  truth for the test, and the DB connection lifecycle
  (private-mode Sandbox in async tests) doesn't get
  exercised by the agent process.

  Extracted from `Nest.Agents.Agent` so the GenServer module
  stays under the 500-line credo limit.
  """

  require Logger

  alias Nest.Persistence

  @doc """
  Persist a freshly-stamped message into the `messages`
  table and bump the agent's `next_message_index` on the
  `agents` row. No-op when persistence is disabled.
  """
  def append_message(agent_id, stamped, new_index) do
    if persistence_enabled?() do
      do_append_message(agent_id, stamped, new_index)
    end
  end

  def archive_and_compact(agent_id, first_index, last_index, archived_count) do
    if persistence_enabled?() do
      do_archive_and_compact(agent_id, first_index, last_index, archived_count)
    end
  end

  defp do_append_message(agent_id, stamped, new_index) do
    case Persistence.insert_message(agent_id, stamped) do
      {:ok, _row} ->
        :ok = Persistence.update_next_message_index(agent_id, new_index)

      {:error, reason} ->
        Logger.warning("Failed to persist message for agent #{agent_id}: #{inspect(reason)}")
    end
  end

  defp do_archive_and_compact(agent_id, first_index, last_index, archived_count) do
    case Persistence.archive_and_compact(agent_id, first_index, last_index, archived_count) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist compaction for agent #{agent_id}: #{inspect(reason)}")
    end
  end

  defp persistence_enabled? do
    Application.get_env(:nest, :persistence, %{})[:enabled] != false
  end
end
