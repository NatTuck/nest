defmodule Nest.Agents.Agent.Init.LoadHeal do
  @moduledoc """
  The general load-time heal for a persisted active sequence that must be
  repaired before the agent comes up `:idle`
  (`notes/enforce-mesages-seq-invariants.md` §4).

  This runs in the *caller's* DB context, via `Agent.pre_load_heal/1`,
  before `GenServer.start_link/1` — never in `init/1` (see the hard rule
  in `Agent.init/1`). The heal persists real rows, so it needs a pid with
  DB access and a Sandbox `$callers` chain back to the connection owner.
  `refresh/1` is the idempotency guard that keeps concurrent callers from
  healing the same tail twice.

  Three shapes are healed, all by appending real, persisted messages
  before the agent comes up `:idle` (without spending an LLM call):

    * a trailing assistant `tool_use` with no result — a turn that died
      before its tool result was committed. The run-time owner is gone,
      so there is nothing to continue: the heal answers the call with
      the canonical `is_error` result, then appends the assistant
      acknowledgement the append-time bridge would otherwise add later.
      This leaves the tail on an `assistant` rather than a `tool`
      (wire role `user`), so the next user turn appends cleanly.
    * a valid slice that ends on a `user` wire role — a crash between
      the user append and the first assistant delta, or a legacy
      compaction segment. The heal appends the load-specific assistant
      ack so an idle agent never ends on a user message.

  A third shape, `{:lost_promises, messages}`, is the same append with a
  different record: a slice that still carries a backgrounded call's promise
  (`MessageList.backgrounded_results/1`), whose batch died with the process
  that owned it. The promise is answered as lost — the model must not wait for
  a message that can never arrive — and the record names the calls it voids, so
  re-classifying the healed tail finds nothing left to record.

  Unlike `Init.NeedsRepair`, none of these shapes is a blocking state — they
  are valid outcomes, not corruption.
  """

  require Logger

  alias Nest.Agents.Agent.Repair
  alias Nest.Messages.Part
  alias Nest.Persistence

  @doc """
  The freshly re-read start attrs for a pending heal, or `nil` when the
  agent row no longer resolves.

  The heal is a read-modify-write: `Persistence.build_attrs_for_start/2`
  classifies the restored sequence and `Agent.pre_load_heal/1` appends the
  heal's rows. Neither is atomic with the other — and
  `build_attrs_for_start/2` itself reads the agent row and the message
  sequence in separate statements — so two concurrent callers for the same
  `{space_id, name}` (two browser tabs joining one agent, or a lobby click
  racing a chat join) can both classify the same pre-heal tail and both
  append it. Re-deriving the classification from a fresh read immediately
  before the append makes the heal idempotent: the caller that loses the
  race gets `load_heal: nil` from this read and appends nothing, and both
  callers start their child from the freshly-read rows.

  An idempotent re-check rather than per-`{space_id, name}` serialization:
  `Nest.Agents.Registry` holds only the *running* agent, and the heal must
  run before that registration exists (`init/1` may never touch the DB),
  so serializing would mean inventing a second lock registry (or a lock
  GenServer). The re-check needs no new machinery, and it stays
  collision-safe for the one interleaving it cannot rule out: callers that
  both pass it classify the same tail, so they derive the same append
  index, and the unique `(agent_id, message_index)` index plus
  `insert_message/3`'s `on_conflict: :nothing` drops the second row.

  Returns `nil` when the agent row is gone: there is no persisted sequence
  left to heal, so the attrs are left untouched.
  """
  @spec refresh(%{space_id: integer(), name: String.t()}) :: map() | nil
  def refresh(%{space_id: space_id, name: name}) do
    case Persistence.build_attrs_for_start(space_id, name) do
      {:ok, fresh} -> fresh
      {:error, _reason} -> nil
    end
  end

  @spec heal(
          Nest.Agents.Agent.t(),
          [Part.ToolUse.t()] | {:bridge, [term()]} | {:lost_promises, [term()]}
        ) ::
          Nest.Agents.Agent.t()
  def heal(state, {:bridge, messages}) do
    Logger.warning(
      "Agent #{state.name} (space #{state.space_id}) loaded an idle sequence ending on a " <>
        "user message; appending the load bridge before idling."
    )

    append_or_keep(state, messages, "load bridge")
  end

  def heal(state, {:lost_promises, messages}) do
    Logger.warning(
      "Agent #{state.name} (space #{state.space_id}) loaded a transcript promising a " <>
        "backgrounded tool result the restart lost; recording the loss before idling."
    )

    append_or_keep(state, messages, "lost backgrounded call")
  end

  def heal(state, tool_uses) do
    Logger.warning(
      "Agent #{state.name} (space #{state.space_id}) loaded an interrupted tool call; " <>
        "answering #{length(tool_uses)} unpaired tool_use id(s) with an error result and idling."
    )

    case Repair.load_heal(tool_uses) do
      [] -> state
      messages -> append_or_keep(state, messages, "interrupted tool call")
    end
  end

  # The load path is terminal, so the append heals the tail and returns
  # `:ok`. A `:cannot_compact` pre-flight refusal is surfaced as
  # `{:invalid, reason, state}`; leave the state untouched and log. The send
  # guard still refuses to send the invalid tail, so we degrade safely
  # rather than crash-loop the Agent. The rescue is a backstop for a
  # genuinely unexpected failure. `shape` names the heal that failed (the
  # `{:bridge, _}` user-tail ack or the interrupted tool call) so the log
  # matches what actually broke.
  defp append_or_keep(state, messages, shape) do
    case Nest.Agents.Agent.__append_messages__(state, messages) do
      {:ok, _stamped, state} ->
        state

      {:invalid, reason, state} ->
        log_unhealed(state, shape, reason)
        state

      {:stale, state} ->
        state
    end
  rescue
    error ->
      log_unhealed(state, shape, Exception.message(error))
      state
  end

  defp log_unhealed(state, shape, reason) do
    Logger.error(
      "Agent #{state.name} (space #{state.space_id}) could not heal its #{shape}: #{reason}"
    )
  end
end
