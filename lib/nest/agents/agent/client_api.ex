defmodule Nest.Agents.Agent.ClientAPI do
  @moduledoc """
  Convenience getters extracted from `Nest.Agents.Agent`
  so the GenServer module stays under the credo 500-line
  cap. Each function is a one-line `GenServer.call` that
  forwards to the corresponding `handle_call` clause in the
  Agent's IntrospectionHandler.

  Kept in a separate module so call sites can
  `alias Nest.Agents.Agent` without pulling in the agent
  GenServer's full alias surface.

  ## Functions

    * `get_public_info/1` — full public info (name, model,
      status, modes, message_count, partial, usage).
    * `get_total_usage/1` — combined
      `usage_totals + descendant_usage` map.
    * `get_messages/1` — active message list.
    * `get_history/1` — archived history (compacted-away
      messages plus `{:compaction, _}` markers).
    * `terminate/1` — `GenServer.stop/2` with normal reason.

  ## Why this lives separately from IntrospectionHandler

  IntrospectionHandler owns the `handle_call` clauses; this
  module owns the "send the call" wrappers so the GenServer's
  exported call surface doesn't grow past the credo cap.
  """

  @doc """
  Terminates the agent process.
  """
  @spec terminate(pid()) :: :ok
  def terminate(pid) do
    GenServer.stop(pid, :normal)
  end

  @doc """
  Returns public information about the agent for the WebSocket protocol.

  Returns a map with :id, :model, :message_count, :status,
  :vocation_id, :partial, :parent_id, :parent_name, :depth,
  :descendant_usage, and :total_usage.
  """
  @spec get_public_info(pid()) :: map()
  def get_public_info(pid) do
    GenServer.call(pid, :get_public_info)
  end

  @doc """
  Returns the combined usage map for the agent: `usage_totals +
  descendant_usage`, computed field-by-field.
  """
  @spec get_total_usage(pid()) :: map() | nil
  def get_total_usage(pid) do
    GenServer.call(pid, :get_total_usage)
  end

  @doc """
  Returns the active message history for the agent.
  """
  @spec get_messages(pid()) :: [Nest.Messages.Message.t()]
  def get_messages(pid) do
    GenServer.call(pid, :get_messages)
  end

  @doc """
  Fetch the API logs for a specific message by index. For assistant
  and system messages, returns the persisted response logs. For user
  and tool messages, rebuilds the request log from conversation
  history on demand.
  """
  @spec get_api_logs(pid(), non_neg_integer(), list()) :: {:ok, [map()]} | {:error, term()}
  def get_api_logs(pid, index, history) do
    GenServer.call(pid, {:get_api_logs, index, history})
  end
end
