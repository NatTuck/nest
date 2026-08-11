defmodule Nest.Agents.Agent.Init.Recovery do
  @moduledoc """
  Construction helper for the `:model_missing` recovery
  state. Builds a fresh `ClientConfig` with `RecoveryClient`
  (so the GenServer stays alive with a stable inert client),
  threads through `Init.seed_from_db` and the api_log restore
  so the agent's message history is intact, and broadcasts
  the recovery signal so any subscribed channel surfaces the
  repair banner.

  The system message was already persisted by `Agent.pre_spawn/1`
  in the caller's pid; this function only constructs the
  in-memory state. No DB work happens in the agent pid.

  Lives in a separate file from `Nest.Agents.Agent` so the
  GenServer module stays under the credo 500-line cap. The
  one-line wrapper at the bottom is delegated back to
  `Agent.build_recovery_state/3` for backwards compatibility
  — both paths converge on the same code.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.Restore
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.RecoveryClient

  @doc """
  Construct the `:model_missing` agent state. See the
  moduledoc for the full flow description.
  """
  @spec build(map(), map(), term()) :: Nest.Agents.Agent.t()
  def build(attrs, model, reason) do
    model_label = model_name(model)

    recovery_client = %ClientConfig{
      client: RecoveryClient,
      model: model_label
    }

    state = Init.build_state(attrs, recovery_client)
    state = %{state | live: %{state.live | status: :model_missing}}

    state =
      Init.seed_from_db(
        state,
        Map.get(attrs, :preloaded_messages, []),
        Map.get(attrs, :last_compaction_index, -1)
      )

    state =
      Restore.attach_rebuilt_api_logs(
        state,
        Map.get(attrs, :preloaded_messages, []),
        Map.get(attrs, :last_compaction_index, -1)
      )

    Broadcasts.model_missing(state.space_id, state.name, model_label, reason)

    state
  end

  # Best-effort label for the unresolved `model` map when the
  # agent is starting in `:model_missing` state. Tolerates
  # atom- or string-keyed params (the persistence layer reads
  # both shapes).
  defp model_name(nil), do: "(unknown)"

  defp model_name(model) when is_map(model) do
    model[:name] || model["name"] || inspect(model)
  end
end
