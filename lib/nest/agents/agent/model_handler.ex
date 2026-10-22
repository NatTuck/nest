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

  ## The model-change notice

  The persisted system prompt (index 0) states the model's name, whether the
  catalog says it accepts image input, and the context limit it budgets against.
  It is deliberately **not** rebuilt on a change (prefix cache), so those facts go
  stale the moment one moves. The change is therefore *announced*: a
  user/assistant pair stating the facts now in force, appended after a
  compaction preflight check (`{:model_notice, facts}`).

  It is a reconciliation rather than a delta — it names the values now in force,
  so two edits in a row cannot leave the agent holding a partial picture — and it
  is emitted only when one of them actually moved: `edit_agent` also carries the
  thinking level, which the prompt says nothing about.

  ## The give-up it performs

  The notice rests the machine (`Phase.rest/4`), and the resting funnel prepends
  the reply give-up (`Machine.GiveUp`). So changing the model of an **idle agent
  that still owes a peer an answer** tells that peer the runtime gave up waiting
  for it — which is surprising for what looks like a settings change, but is the
  same rule every resting transition follows (the workspace notice included): a
  rest ends the turn, and a turn that ends owing a reply cannot keep working.
  `MachineDebtTest` asserts it for this site like the others.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.NoticeDelivery
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.Agent.Turn
  alias Nest.Messages.Assistant
  alias Nest.Messages.Header
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Models.MultiModal
  alias Nest.Persistence

  @typedoc """
  The facts about the agent's model that its prompt states, and that a model
  change therefore has to announce: the model's name, whether the merged catalog
  says it accepts image input, and the context limit it budgets against.

  The context limit's **source** is deliberately not one of them, although the
  prompt names it ("resolved from config"): the number is what the agent budgets
  against and what a stale line gets wrong, whereas the provenance is not
  actionable and would be one more sentence in every notice. A change that keeps
  the limit and moves only the source therefore announces nothing, and the
  parenthetical stays as it was.

  `:kind` tags the map for the one place that has to tell two staged notices
  apart (`Nest.Agents.Agent.Machine.Compaction.resume_notice/2`); a
  space-environment change carries `:workspace` there.
  """
  @type facts :: %{
          required(:kind) => :model,
          required(:model) => String.t() | nil,
          required(:verdict) => :supported | :unsupported | :unknown,
          required(:context_limit) => integer()
        }

  @doc """
  The facts the prompt states about a model, from its name and its context limit.

  The verdict is `Nest.Models.MultiModal.input_support/2`'s — the same one
  `file-read`'s media gate reads — so the notice, the prompt and the tool cannot
  disagree about the same model.
  """
  @spec facts(String.t() | nil, integer()) :: facts()
  def facts(name, context_limit) do
    %{
      kind: :model,
      model: name,
      verdict: MultiModal.input_support(name, :image),
      context_limit: context_limit
    }
  end

  @doc """
  The notice user/assistant pair appended when the agent's model changes.

  The user row is the runtime speaking — it is a notice, not the human's words —
  so it carries the runtime's header in `mode` (`Nest.Messages.Header`), the mode
  being the recipient's, exactly as every other delivered row states it. The
  assistant row is the acknowledgement, which carries no header.
  """
  @spec notice_pair(facts(), String.t()) :: [Agent.message()]
  def notice_pair(facts, mode) do
    [
      {:user,
       %User{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [%Part.Text{text: notice_text(facts, mode)}],
         metadata: %{"mode" => mode},
         api_logs: []
       }},
      {:assistant,
       %Assistant{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [%Part.Text{text: "Model change confirmed."}],
         api_logs: []
       }}
    ]
  end

  @doc """
  The pair's user row, in one place: `notice_pair/2` builds it and the settle's
  outcome check (`Nest.Agents.Agent.NoticeDelivery`) looks for exactly this text
  in the rows a settle added.
  """
  @spec notice_text(facts(), String.t()) :: String.t()
  def notice_text(facts, mode), do: Header.put(body(facts), :runtime, mode)

  # Current facts, no meta-commentary — the same voice as the space-environment
  # notice. The verdict sentence and the budget arithmetic are the prompt's own
  # (`SystemPrompt.model_verdict_sentence/1`, `SystemPrompt.working_budget/1`), so
  # a notice and a prompt can never state different things about the same model:
  # the limit is the number the agent budgets against, so a stale one is the whole
  # reason this sentence exists.
  defp body(%{model: name, verdict: verdict, context_limit: limit}) do
    {reserve, effective} = SystemPrompt.working_budget(limit)

    "Your model changed. It is now \"#{name}\". " <>
      SystemPrompt.model_verdict_sentence(verdict) <>
      " Its context limit is #{limit} tokens, of which ~#{reserve} tokens are reserved " <>
      "for compaction, giving a working token budget of ~#{effective}. " <>
      "Compaction will trigger automatically when the conversation gets too big; " <>
      "never stop working due to context concerns."
  end

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
    # The facts the prompt states *now*, read before the change: the notice is
    # only owed when one of them moves.
    old_facts = facts(state.client_config.model, state.llm_metrics.context_limit)

    case Config.create_client_config(new_model) do
      {:error, reason} ->
        {:reply, {:error, {:invalid_model, reason}}, state}

      {:ok, client_config} ->
        case Persistence.update_agent_model(state.space_id, state.name, new_model) do
          {:error, reason} ->
            {:reply, {:error, reason}, state}

          :ok ->
            new_state = apply_new_model(state, new_model, client_config)
            new_facts = facts(new_state.client_config.model, new_state.llm_metrics.context_limit)

            state =
              new_state
              |> unblock_and_announce(old_status)
              |> announce_model_change(old_facts, new_facts)

            {:reply, :ok, state}
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

  # The prompt's model section is composed once, at start, and never rebuilt
  # (prefix cache), so a change leaves it naming the old model and stating the
  # old verdict — and the context limit the agent budgets against is stale too.
  # The notice is the only place that can correct it.
  #
  # Nothing is said when the facts the prompt states are unchanged: `edit_agent`
  # also carries the thinking level, which the prompt says nothing about, so a
  # thinking-only edit owes no notice (it is still a real edit — the row and the
  # client config moved).
  defp announce_model_change(state, facts, facts), do: state

  defp announce_model_change(state, _old_facts, new_facts) do
    {:ok, settled} = Turn.settle(state, {:model_notice, new_facts})

    case NoticeDelivery.outcome(state, settled, notice_text(new_facts, state.live.mode)) do
      # `:deferred` is a delivery: a compaction is carrying the pair and will
      # append it when it commits.
      outcome when outcome in [:appended, :deferred] ->
        settled

      # Nothing has it and nothing is in flight to add it, so the agent is left
      # describing its old model. Worth a warning, and *not* a failed model
      # change: the row is already persisted, and the change itself is what the
      # operator asked for.
      {:error, status} ->
        Logger.warning(
          "model change not announced on agent #{inspect(state.name)} " <>
            "(#{inspect(status)}): the new model is persisted, but the agent's " <>
            "transcript still describes the old one"
        )

        settled
    end
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
