defmodule Nest.Agents.Agent.Persistence do
  @moduledoc """
  Agent-side glue around `Nest.Persistence`.

  Defense-in-depth: each function returns `:ok` immediately
  when the runtime `:persistence_enabled` config flag is
  `false`. Production code never disables persistence; the
  no-op branch is a guardrail for manual dev experiments.
  """

  require Logger

  alias Nest.Persistence

  @doc """
  Persist a freshly-stamped message into the `messages`
  table and bump the agent's `next_message_index`.
  """
  def append_message(space_id, agent_id, stamped, new_index)
      when is_integer(space_id) and is_binary(agent_id) do
    if persistence_enabled?() do
      do_append_message(space_id, agent_id, stamped, new_index)
    else
      :ok
    end
  end

  def append_message(_space_id, _agent_id, _stamped, _new_index), do: :ok

  defp do_append_message(space_id, agent_id, stamped, new_index) do
    case Persistence.insert_message(space_id, agent_id, stamped) do
      {:ok, _row} ->
        :ok = Persistence.update_next_message_index(space_id, agent_id, new_index)

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist message for agent #{agent_id}: #{inspect(reason)}")
    end
  end

  def record_compaction(
        space_id,
        agent_id,
        marker_index,
        archived_count,
        tokens_compacted \\ nil,
        tokens_compacted_to \\ nil
      ) do
    if persistence_enabled?() do
      do_record_compaction(
        space_id,
        agent_id,
        marker_index,
        archived_count,
        tokens_compacted,
        tokens_compacted_to
      )
    else
      :ok
    end
  end

  defp do_record_compaction(
         space_id,
         agent_id,
         marker_index,
         archived_count,
         tokens_compacted,
         tokens_compacted_to
       ) do
    case Persistence.record_compaction(
           space_id,
           agent_id,
           marker_index,
           archived_count,
           tokens_compacted,
           tokens_compacted_to
         ) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist compaction for agent #{agent_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp persistence_enabled? do
    Application.get_env(:nest, :persistence, %{})[:enabled] != false
  end
end
