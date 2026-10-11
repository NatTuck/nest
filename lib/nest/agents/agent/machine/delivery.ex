defmodule Nest.Agents.Agent.Machine.Delivery do
  @moduledoc """
  The action assembly for a message delivered into a turn that fits it
  (issue #36).

  Two sites deliver a message into a turn: `Machine.Transitions.start_chat/3`
  (the `:idle` chat request and every inbox drain at a turn boundary) and
  `Machine.Backgrounding.background/3` (a message that arrives while a tool
  batch is executing). They differ in exactly two things — what they append
  before the delivered message (nothing, or the synthetic backgrounded result
  and its acknowledgement) and which phase the machine enters — and share
  everything else:

    * the context-threshold notice,
    * the reply obligation the delivery incurs (`Machine.owe_replies/2`,
      issue #31 §1.3: incurred at *delivery*, never at enqueue — a `:query`
      still queued behind a compaction, a block or a restart has not been
      delivered and owes nothing),
    * the consume half of peek-then-consume (issue #26), and
    * the `:iterate` that continues the turn with the delivered message.

  That shared half lives here, and only here. The backgrounding path once
  reimplemented it and silently dropped the notice and the debt — a `:query`
  delivered mid-batch incurred nothing, so a later failure, block or restart
  gave up nothing for that requester — and this module exists so that
  divergence class cannot reappear.

  Pure: `fits/4` returns the actions and the machine with the notice
  bookkeeping and the debt applied. The caller owns the phase, because the two
  callers enter it from different shapes.

  ## Where the notice pair lands

  A notice pair is assistant-shaped, so it can never follow the delivered user
  message: the request would end on an assistant and
  `Preflight.validate_request/1` would fail it (`:no_trailing_assistant`). It
  therefore lands *between* the caller's own append (`pre`, empty at the turn
  boundary) and the delivered message. `pre` is also the transcript the pair is
  built against, which is what lets the backgrounding path fire a notice at
  all: by then the synthetic result has answered the unpaired `tool_use` the
  batch's tail carried, while built against the tail itself
  `NoticePairInjector.build_pair/3` would defer — and the notice could never
  fire on that path.
  """

  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Agents.Agent.Turn.ContextReminder

  @doc """
  Assemble the `:fits` delivery of `user` into `m`.

  `pre` is what the caller appends before the delivered message — the synthetic
  backgrounded result and its acknowledgement, or `[]` at the turn boundary —
  and `entries` is the inbox batch the delivery consumed (`nil` for the human
  `{:chat_request, …}` path, which has no queue behind it).

  Returns the actions (appends, the notice, the consume, the `:iterate`) and
  the machine with the notice bookkeeping and the reply debt applied. The
  caller enters its phase and starts the turn.
  """
  @spec fits(Machine.t(), [term()], [term()] | nil, term()) :: {[term()], Machine.t()}
  def fits(m, pre, entries, user) do
    base = Phase.messages(m) ++ pre
    {notice_actions, m} = notice_actions(m, base, base ++ [user])
    m = Machine.owe_replies(m, Inbox.query_senders(entries))

    {appends(pre, user, notice_actions) ++ consume_actions(entries) ++ [:iterate], m}
  end

  # One append when there is no notice pair to land in between; with one, the
  # pair has to sit between the caller's own batch and the delivered message,
  # so the batch is split around it.
  defp appends(pre, user, []), do: append(pre ++ [user])
  defp appends(pre, user, notice_actions), do: append(pre) ++ notice_actions ++ append([user])

  defp append([]), do: []
  defp append([message]), do: [{:append, message}]
  defp append(messages), do: [{:append_many, messages}]

  # The drain's consume half (issue #26): emitted *after* the append, in the
  # same settle, so the wire sees the message land and then the queue empty.
  # The order is defensive: an append the appender refuses halts the action
  # list (`{:append_result, :invalid | :stale, _}`), so the consume never runs
  # and the entries stay queued and visible. (On this branch the append cannot
  # be refused — `:fits` implies the preflight passes — but the position keeps
  # the invariant true by construction.) Nothing for a chat request.
  defp consume_actions(entries) when entries in [nil, []], do: []
  defp consume_actions(entries), do: [{:consume_inbox, entries}]

  # The notice is built against `base` — the transcript the pair will land on —
  # while its threshold is decided from `projected`, the transcript that
  # includes the delivered message. `build_pair/3` returning `:deferred` leaves
  # the threshold unannounced so a later, safe boundary can still fire it.
  defp notice_actions(m, base, projected) do
    limit = m.work.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      used = ContextReminder.estimate_messages(projected)
      crossed = m.work.ctx.crossed_thresholds

      case ContextReminder.highest_unannounced(used, limit, crossed) do
        nil -> {[], m}
        atom -> build_notice(m, base, atom, used, crossed)
      end
    else
      {[], m}
    end
  end

  defp build_notice(m, base, atom, used, crossed) do
    compact? = ContextReminder.compact_available?(m.work.ctx.tools)
    notice = ContextReminder.notice_text(atom, compact?)
    ack = ContextReminder.ack_text_for(atom, compact?)

    spec = %{kind: :context, attention: "Context?", notice: notice, ack: ack, threshold: atom}

    case NoticePairInjector.build_pair(base, spec, :user_agent) do
      {:ok, pair} ->
        set = MapSet.put(crossed, atom)

        actions = [
          {:append_many, pair},
          {:set_crossed_thresholds, set},
          {:set_context_projection, used}
        ]

        {actions, Phase.put_ctx(m, crossed_thresholds: set, context_projection: used)}

      :deferred ->
        {[], m}
    end
  end
end
