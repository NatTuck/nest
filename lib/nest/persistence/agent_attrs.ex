defmodule Nest.Persistence.AgentAttrs do
  @moduledoc """
  Agent-row attribute mutators extracted from `Nest.Persistence`
  so the parent module stays under the credo 500-line cap.

  `update_agent_model/3` and `fetch_all_agents/0` are the only
  agent-row UPDATEs the runtime path issues outside of
  `insert_agent/1` and the message-write helpers.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Persistence
  alias Nest.Repo

  @spec update_agent_model(integer(), String.t(), map()) :: :ok | {:error, term()}
  def update_agent_model(space_id, name, model_map) when is_map(model_map) do
    if Application.get_env(:nest, :persistence, %{})[:enabled] != false do
      do_update(space_id, name, model_map)
    else
      :ok
    end
  end

  defp do_update(space_id, name, model_map) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        from(a in PersistedAgent, where: a.id == ^agent_id)
        |> Repo.update_all(
          set: [
            model: model_map,
            updated_at: Persistence.now()
          ]
        )

        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec fetch_all_agents_for_space(integer()) :: [PersistedAgent.t()]
  def fetch_all_agents_for_space(space_id) when is_integer(space_id) do
    if Application.get_env(:nest, :persistence, %{})[:enabled] != false do
      from(a in PersistedAgent, where: a.space_id == ^space_id, order_by: a.name)
      |> Repo.all()
    else
      []
    end
  end
end
