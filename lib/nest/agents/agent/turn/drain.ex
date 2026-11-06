defmodule Nest.Agents.Agent.Turn.Drain do
  @moduledoc """
  The inbox drain: what the next batch is, what it renders as, and what
  consuming it means.

  Split out of `Nest.Agents.Agent.Turn.Executor` so the peek's three outcomes —
  empty, a deliverable batch, a batch that could not be admitted — stay in one
  function instead of three nested cases.

  The drain is peek-then-consume (issue #26): `peek/1` applies the batch's mode
  and renders the content but leaves the queue alone, so a delivery that parks
  (a compaction, a block) or fails leaves the entries queued and visible.
  `consume/2` is emitted only by the branch that appended the message.

  A batch that is too large to inline and cannot be written to the agent's
  scratch dir is `{:error, reason}`: the entries stay queued and the reason is
  a visible `chat:error`. Never inline something over the budget to rescue the
  drain — the send gate is a never-happen tripwire, not a place to absorb one.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Timeline
  alias Nest.Messages.Segment
  alias Nest.Sandbox.Mounts

  @type peek ::
          :empty | {:error, String.t()} | {Agent.t(), [map()], String.t(), [Segment.t()] | nil}

  @doc """
  The next batch to deliver, the state its mode applied, its content, and the
  parts the delivered row has (`nil` when the batch is delivered whole).

  The mode comes first: the delivered message is *rendered* with the mode the
  turn will run in (a peer delivery's header states it), and `applied_mode/2`
  is what decides it — the batch's own request, resolved. It is *not*
  re-authorized here, and that is deliberate: the authority ran where the change
  was **asked** (the send tool, with the sender's mode as it was then), and the
  actor was entitled when it asked. A delivery-time re-check would refuse a
  change that was legitimate when it was made, which is a different rule, not a
  stricter one.

  The mode change is published before the content is returned:
  `Broadcasts.status/1` is the only carrier of `currentMode`, and the settle
  loop broadcasts only on a status *change* — which this drain deliberately does
  not cause (the phase stays `:generating`) — so it is published here or the UI
  keeps the old one until the turn ends.
  """
  @spec peek(Agent.t()) :: peek()
  def peek(state) do
    case Inbox.batch(state.live.inbox) do
      [] -> :empty
      batch -> peek_batch(state, batch)
    end
  end

  defp peek_batch(state, batch) do
    mode = applied_mode(state, batch)
    mode_changed? = mode != state.live.mode
    state = %{state | live: %{state.live | mode: mode}}

    case Inbox.combine_and_offload(batch, state) do
      {:ok, content, parts} ->
        if mode_changed?, do: Broadcasts.status(state)
        {state, batch, content, parts}

      # Nothing was delivered under the mode this peek applied, so the rejected
      # state (with its mode change) is dropped rather than returned.
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Drop exactly the peeked batch, not the whole queue.

  The executor runs synchronously inside one settle, so nothing can be enqueued
  between the peek and the consume, and anything the peek did not deliver stays
  queued. The frame is the removal delta for exactly those ids (issue #27) —
  `Inbox.consume_and_broadcast/2` owns both the write and the frame so they
  cannot disagree.
  """
  @spec consume(Agent.t(), [map()]) :: {Agent.t(), :continue}
  def consume(state, entries) do
    state = Inbox.consume_and_broadcast(state, entries)
    Timeline.drained(state, entries)
    {state, :continue}
  end

  @doc "Surface a batch that could not be admitted, leaving it queued."
  @spec failed(Agent.t(), String.t()) :: {Agent.t(), :continue}
  def failed(state, reason) do
    Broadcasts.error(state.space_id, state.name, nil, reason, "Turn.Executor.drain_inbox")
    {state, :continue}
  end

  # One mode per delivered batch: the most recent entry that carries a mode wins
  # (`Inbox.drain_mode/1`) — the human's own request, or a peer's `set_mode`,
  # which rides the message it belongs to — and the agent's current mode stands
  # when no entry does. The winner is resolved against the modes this build has
  # (`Nest.Modes`) exactly as `ChatPipeline.handle_chat/3` resolves an idle
  # turn's request, so `state.live.mode` — and with it the UI's `currentMode` —
  # never holds a mode nothing can honour. Applied here, never when the entry was
  # queued: `state.live.mode` feeds `ctx.mode`/`ctx.caps`, which `Turn.prepare/1`
  # rebuilds on every settle, so setting it on arrival would re-resolve the caps
  # of the *ongoing* turn's remaining tool calls. A drain that consumes nothing
  # — a decline, a park, a block — undoes the application
  # (`Turn.restore_undelivered_mode/3`) for that same reason: the entry is still
  # queued, so the mode must not stick.
  defp applied_mode(state, entries) do
    case Inbox.Mode.drain_mode(entries) do
      nil ->
        state.live.mode

      requested ->
        {resolved, _caps} =
          ChatPipeline.resolve_mode_and_caps(requested, state.vocation, Mounts.from_agent(state))

        resolved
    end
  end
end
