defmodule Nest.Agents.Agent.ModelHandler do
  @moduledoc """
  `handle_call/3` clauses for per-agent runtime mutations
  (specifically `{:set_model, _}`, the recovery-flow handler).

  Extracted from `Nest.Agents.Agent.IntrospectionHandler`
  so the parent module stays under the credo 500-line cap,
  and so the model-change flow's "refuse while busy →
  validate → persist → mutate state → broadcast" sequence
  lives in one place.

  The handler is dispatched from `Nest.Agents.Agent.handle_call/3`'s
  catch-all (which forwards to `IntrospectionHandler.handle/3`)
  via `IntrospectionHandler.handle/3`'s forwarding clause.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.WorkspaceHandler
  alias Nest.Persistence

  @doc """
  Change the agent's resolved LLM client (`client_config`)
  and persisted `model` map.

  Allowed only in `:idle` and `:model_missing` states;
  rejects while the agent is streaming, executing tools, or
  in any other status (mid-stream model switches would
  silently break in-flight tool pairing and stream bookkeeping).

  Resolves a fresh `ClientConfig` via
  `Config.create_client_config/1`, persists the new `model`
  to the DB, and re-runs `Init.initial_context_limit/1` so
  the metrics reflect the new model's context window.

  `:model_missing` → `:idle` transition drives the ChatPage
  repair banner off; status broadcasts on `agent:<name>` so any
  subscribed channel receives the new `model` field.
  """
  @spec handle(map(), GenServer.from(), Agent.t()) :: GenServer.reply()
  def handle({:set_model, new_model}, _from, state) when is_map(new_model) do
    if state.live.status in [:idle, :model_missing] do
      perform_set_model(state, new_model)
    else
      {:reply, {:error, :agent_busy}, state}
    end
  end

  # Combined edit: change the agent's model (and thinking level) and
  # working directory in one call. Validates both before persisting, so
  # an invalid model or a missing workspace for a workspace-requiring
  # vocation leaves the agent unchanged. Broadcasts status once.
  def handle({:edit_agent, new_model, workspace_path}, _from, state) when is_map(new_model) do
    if state.live.status in [:idle, :model_missing] do
      perform_edit_agent(state, new_model, normalize_workspace(workspace_path))
    else
      {:reply, {:error, :agent_busy}, state}
    end
  end

  defp perform_edit_agent(state, new_model, workspace_path) do
    case Config.create_client_config(new_model) do
      {:error, reason} ->
        # Wrap the model-resolution error like `perform_set_model/2`
        # does, so `AgentErrors.edit_payload/2` maps it to
        # `invalid_model` rather than crashing on the struct.
        {:reply, {:error, {:invalid_model, reason}}, state}

      {:ok, client_config} ->
        with :ok <- validate_workspace(state, workspace_path),
             :ok <- Persistence.update_agent_model(state.space_id, state.name, new_model),
             :ok <-
               Persistence.update_agent_workspace(state.space_id, state.name, workspace_path) do
          state = apply_new_model(state, new_model, client_config)
          {state, _workspace_reply} = WorkspaceHandler.apply_workspace(state, workspace_path)
          Broadcasts.status(state)
          {:reply, :ok, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  # A vocation that writes to `:workspace` requires a non-null working
  # directory; otherwise the workspace field is absent (nil).
  defp validate_workspace(state, workspace_path) do
    if Nest.Vocations.requires_workspace?(state.vocation) and is_nil(workspace_path) do
      {:error, :workspace_required}
    else
      :ok
    end
  end

  defp normalize_workspace(nil), do: nil
  defp normalize_workspace(""), do: nil
  defp normalize_workspace(path), do: path

  # Top-level "validate → persist → mutate → broadcast"
  # sequence. Returns the GenServer's reply tuple so the call to
  # `perform_set_model/2` reads as a straight-line pipeline.
  defp perform_set_model(state, new_model) do
    case Config.create_client_config(new_model) do
      {:error, reason} ->
        {:reply, {:error, {:invalid_model, reason}}, state}

      {:ok, client_config} ->
        case Persistence.update_agent_model(state.space_id, state.name, new_model) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          :ok ->
            new_state = apply_new_model(state, new_model, client_config)
            Broadcasts.status(new_state)
            {:reply, :ok, new_state}
        end
    end
  end

  # Mutate the state for a new model/client. Does NOT broadcast — the
  # caller owns the status broadcast so a combined edit can broadcast
  # once after applying both model and workspace.
  defp apply_new_model(state, new_model, client_config) do
    {context_limit, context_limit_source} = Init.initial_context_limit(new_model)

    state = %{
      state
      | model: new_model,
        client_config: client_config,
        # Reset the threshold set so reminders re-fire under
        # the new model's context window. Mirrors the post-
        # compaction reset in `Compaction.ResultHandler`.
        # Must be a `MapSet.new()` (not `%{}`) — the field is
        # structurally a MapSet across every other writesite
        # and `ContextReminder.highest_unannounced/3` calls
        # `MapSet.member?/2` directly. Regression test in
        # `test/nest/agents/agent_change_model_test.exs`.
        live: %{state.live | crossed_thresholds: MapSet.new()},
        llm_metrics: %{
          state.llm_metrics
          | context_limit: context_limit,
            context_limit_source: context_limit_source
        }
    }

    # `:model_missing` recovery transition — flag flips to
    # `:idle` so the ChatPage's repair banner clears.
    if state.live.status == :model_missing do
      %{state | live: %{state.live | status: :idle}}
    else
      state
    end
  end
end
