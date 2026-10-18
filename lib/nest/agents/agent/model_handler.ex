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
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn
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
    if Machine.status_for(state.live.machine) in [:idle, :model_missing] do
      perform_set_model(state, new_model)
    else
      {:reply, {:error, :agent_busy}, state}
    end
  end

  # The agent edit: model (and thinking level). It is the same operation as
  # `{:set_model, _}` now that the working directory is a *space* property and
  # has no per-agent edit — the two channel events stay because they are two
  # client gestures, but they land here.
  def handle({:edit_agent, new_model}, _from, state) when is_map(new_model) do
    if Machine.status_for(state.live.machine) in [:idle, :model_missing] do
      perform_set_model(state, new_model)
    else
      {:reply, {:error, :agent_busy}, state}
    end
  end

  # Top-level "validate → persist → mutate → broadcast"
  # sequence. Returns the GenServer's reply tuple so the call to
  # `perform_set_model/2` reads as a straight-line pipeline.
  defp perform_set_model(state, new_model) do
    old_status = Machine.status_for(state.live.machine)

    case Config.create_client_config(new_model) do
      {:error, reason} ->
        {:reply, {:error, {:invalid_model, reason}}, state}

      {:ok, client_config} ->
        case Persistence.update_agent_model(state.space_id, state.name, new_model) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          :ok ->
            new_state = apply_new_model(state, new_model, client_config)
            {:reply, :ok, unblock_and_announce(new_state, old_status)}
        end
    end
  end

  # Apply the `:unblocked` transition through the settle loop so the
  # machine's `:drain_inbox` action runs (the `:model_missing` recovery),
  # then announce the status. `Turn.settle/2` broadcasts when the status
  # changes; when the agent was already idle the status is unchanged, so
  # we broadcast explicitly to push the new model to subscribers.
  defp unblock_and_announce(state, old_status) do
    {:ok, state} = Turn.settle(state, {:unblocked})

    if Machine.status_for(state.live.machine) == old_status do
      Broadcasts.status(state)
    end

    announce_pending_space_notice(state)
  end

  # A `:model_missing` agent was blocked *at start*, so the start path's notice
  # never ran and nothing else consumes `space_notice_pending`: the flag is only
  # read when an agent starts. Its mounts have moved (a space edit cast them), so
  # the transcript still owes the agent the pair — send it the same self-message
  # the start path uses, and the existing handler appends it and clears the flag.
  #
  # One read on the recovery path, which is a user action, not a hot path.
  defp announce_pending_space_notice(state) do
    case Persistence.fetch_agent(state.space_id, state.name) do
      {:ok, %{space_notice_pending: true}} -> send(self(), :space_notice_pending)
      _no_pending_notice -> :ok
    end

    state
  end

  # Mutate the state for a new model/client. Does NOT broadcast — the
  # caller owns the status broadcast.
  defp apply_new_model(state, new_model, client_config) do
    {context_limit, context_limit_source} = Init.initial_context_limit(new_model)

    %{
      state
      | model: new_model,
        client_config: client_config,
        # Reset the threshold set so reminders re-fire under
        # the new model's context window. Mirrors the post-
        # compaction reset in `Machine.Compaction`.
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
  end
end
