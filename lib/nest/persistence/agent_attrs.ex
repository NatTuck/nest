defmodule Nest.Persistence.AgentAttrs do
  @moduledoc """
  Agent-row attribute mutators extracted from `Nest.Persistence`
  so the parent module stays under the credo 500-line cap.

  `update_agent_model/2` and `fetch_all_agents/0` are the only
  agent-row UPDATEs the runtime path issues outside of
  `insert_agent/1` and the message-write helpers. Both are
  gated on the same `:persistence_enabled` app env as
  `append_message/3` in `Nest.Agents.Agent.Persistence`.

  Persistence-enabled semantics:

    * `update_agent_model/2` issues an `UPDATE agents SET
      model = $1, updated_at = now()` against the row whose
      `name` matches `name`. Returns `:ok` on success,
      `{:error, :not_found}` when no row exists.
    * `fetch_all_agents/0` returns every row in `name` order.

  Persistence-disabled (`config/test.exs:25` defaults to false):
  both return the no-op answer (`:ok` / `[]`) so tests that
  don't want a sandbox dependency run cleanly.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Persistence
  alias Nest.Repo

  @doc """
  Update the `model` column on an agent row. Used by the
  `Agent.set_model/2` recovery flow when the user picks a
  replacement model from the UI.

  Gated on the same `:persistence_enabled` flag as
  `append_message/3` — when persistence is off (the default
  test setup), this is a no-op and returns `:ok`. The
  runtime state in `Agent.set_model/2` is the source of
  truth in that case; persistence is purely the on-restart
  hydrate.

  Touches `updated_at` so the lobby can sort "recently
  reconfigured" agents to the top in the future if desired.
  """
  @spec update_agent_model(String.t(), map()) :: :ok | {:error, term()}
  def update_agent_model(name, model_map) when is_map(model_map) do
    if Application.get_env(:nest, :persistence, %{})[:enabled] != false do
      do_update(name, model_map)
    else
      :ok
    end
  end

  defp do_update(name, model_map) do
    case Persistence.fetch_agent_by_name(name) do
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

  @doc """
  List every persisted agent row, ordered by name. Used by
  `Agents.list_broken_agents/0` to assemble the lobby's
  "broken agents" payload (rows whose persisted `model` no
  longer resolves to a runtime provider).

  Returns `[]` when persistence is disabled (the default test
  setup) so the read path doesn't trip over the Ecto Sandbox's
  private-mode restrictions. The lobby simply won't include
  a `broken_agents` payload in that environment, which is
  consistent with the rest of the DB-backed `init` fields.
  """
  @spec fetch_all_agents() :: [PersistedAgent.t()]
  def fetch_all_agents do
    if Application.get_env(:nest, :persistence, %{})[:enabled] != false do
      from(a in PersistedAgent, order_by: a.name)
      |> Repo.all()
    else
      []
    end
  end
end
