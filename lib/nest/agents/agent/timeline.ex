defmodule Nest.Agents.Agent.Timeline do
  @moduledoc """
  The agent runtime's `Nest.Timeline` emitters.

  `notes/w2-emitters.md` is the site → event → payload table this module
  implements: every payload is built from values the caller already has, and
  nothing is re-derived from a second source of truth. Each public function
  records at most one event (a `tool` batch records one per result) and always
  returns `:ok`.

  Two properties make an emitter safe to call from inside a turn:

    * **Nothing is built when recording is off.** `Nest.Timeline.record/4` is
      cheap on its own, but some payloads are not (`ConversationSize.size/1`
      walks and tokenizes the message list), so every emitter checks
      `Nest.Timeline.enabled?/0` before building anything — the payload builder
      is a thunk that is only called when it will be written.
    * **A payload builder cannot break a turn.** The thunk runs inside a
      `rescue`, so an emitter that meets a state shape it did not expect logs
      and returns `:ok` rather than raising into the settle.

  The `agent` on every event is the *owning* agent: a child event emitted while
  handling that child's outcome passes the parent, with the child's name in
  `name` — that is what makes the child graph read as the parent's view.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.GiveUp
  alias Nest.Tokens.Budget
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Reserve

  @doc """
  The message indices of `state`'s active conversation, or `[]` when recording
  is off.

  A turn's `message_indices` are a *diff* of this list. The indices are stamped
  by the executor inside the driver's `run/6`, one settle later than the
  transition that decided them, and no later settle can recover them (its
  `prepare/1` has already replaced the machine), so the driver snapshots before
  the step and diffs after the actions have run.
  """
  @spec snapshot(Agent.t()) :: [non_neg_integer()]
  def snapshot(state) do
    if Nest.Timeline.enabled?(), do: indices(state), else: []
  end

  @doc "The indices `state` gained since `before` (`[]` when recording is off)."
  @spec added([non_neg_integer()], Agent.t()) :: [non_neg_integer()]
  def added(before, state) do
    if Nest.Timeline.enabled?() do
      seen = MapSet.new(before)
      Enum.reject(indices(state), &MapSet.member?(seen, &1))
    else
      []
    end
  end

  @doc "A machine transition: one `turn` event per `Machine.step/2` call."
  @spec turn(Agent.t(), term(), Machine.t(), Machine.t(), [non_neg_integer()]) :: :ok
  def turn(state, event, from, to, indices) do
    record(state, :turn, fn ->
      %{
        event: Machine.event_tag(event),
        from: placement(from),
        to: placement(to),
        iteration: to.work.iteration,
        max_iterations: to.work.max_iterations,
        message_indices: indices
      }
    end)
  end

  @doc """
  The debt changes one step made, one `debt` event each.

  The obligation is pure machine state and every writer of it is a transition,
  so the diff of the two machines *is* the record — and it cannot drift from the
  writers the way a hand-placed emitter at each one would. Each change has
  exactly one meaning:

    * a sender present only in `to` was owed at delivery (`owe_replies/2`, from
      `start_chat/3`'s `:fits` branch) — `how: "delivered"`, no reminder yet;
    * a sender present only in `from` was discharged by the reply-sent
      transition (`discharge_reply/2` is the only in-step clear);
    * a sender whose count grew was reminded by the gate
      (`ReplyReminder.decision/2` → `count_reminders/2`).
  """
  @spec debt_changes(Agent.t(), Machine.t(), Machine.t()) :: :ok
  def debt_changes(state, %Machine{} = from, %Machine{} = to) do
    if Nest.Timeline.enabled?() do
      owed_before = from.owed_replies
      owed_after = to.owed_replies

      set_debts(state, owed_before, owed_after)
      cleared_debts(state, owed_before, owed_after)
      reminded_debts(state, owed_before, owed_after)
    end

    :ok
  end

  defp set_debts(state, owed_before, owed_after) do
    owed_after
    |> Enum.reject(fn {peer, _count} -> Map.has_key?(owed_before, peer) end)
    |> Enum.each(fn {peer, _count} ->
      debt(state, :set, peer: peer, reminders_used: 0, how: "delivered")
    end)
  end

  defp cleared_debts(state, owed_before, owed_after) do
    owed_before
    |> Enum.reject(fn {peer, _count} -> Map.has_key?(owed_after, peer) end)
    |> Enum.each(fn {peer, count} ->
      debt(state, :cleared, peer: peer, reminders_used: count, how: "reply_sent")
    end)
  end

  defp reminded_debts(state, owed_before, owed_after) do
    owed_after
    |> Enum.filter(fn {peer, count} -> count > Map.get(owed_before, peer, 0) end)
    |> Enum.each(fn {peer, count} ->
      debt(state, :reminded, peer: peer, reminders_used: count, how: "gate")
    end)
  end

  @doc """
  One `inbox` event.

  `fields` carries `from`, `kind` and `disposition`, plus `content` (recorded as
  its size), `bytes` (a size directly, for a drain's whole batch), `mode` and
  `count`. `mode` defaults to `nil` (the peer path has no mode) and `count` to
  `nil` (a refusal never queued).

  `fields` may also be a 0-arity function returning them, for a caller whose
  fields are *computed* (a drain sums its batch): the computation then happens
  inside `record/3`'s thunk — only when recording is on, and inside the rescue —
  instead of eagerly in the caller's frame, which is what `drained/2` needs.
  """
  @spec inbox(Agent.t(), atom(), keyword() | (-> keyword())) :: :ok
  def inbox(state, action, fields) when is_function(fields, 0) do
    record(state, :inbox, fn -> inbox_payload(action, fields.()) end)
  end

  def inbox(state, action, fields) do
    record(state, :inbox, fn -> inbox_payload(action, fields) end)
  end

  defp inbox_payload(action, fields) do
    fields = Map.new(fields)

    Map.merge(
      %{
        action: action,
        mode: nil,
        count: nil,
        bytes: Nest.Timeline.bytes(Map.get(fields, :content))
      },
      Map.delete(fields, :content)
    )
    |> Map.update(:disposition, nil, &disposition/1)
  end

  # A disposition is the value the sender was given, and the refusal paths hand
  # back a tuple (`{:status, :needs_repair}`). A tuple cannot be encoded, and
  # the writer's response to that is a stub that drops the whole payload, so the
  # shape is rendered instead — the line keeps every field and a reader still
  # sees exactly what the sender was told.
  defp disposition(value) when is_binary(value) or is_atom(value) or is_integer(value), do: value
  defp disposition(value), do: inspect(value)

  @doc """
  The `drained` line: the batch a drain actually delivered.

  Emitted from the consume half of peek-then-consume, so a peek that parks
  (a compaction, a `:cannot_compact` block) records nothing — the entries are
  still queued and visible. `bytes` is the delivered entries' own content size
  (the combined string's separators and sender labels are the renderer's, not
  the messages'), and `mode` / `disposition` are the mode the drain resolved.
  """
  @spec drained(Agent.t(), [map()]) :: :ok
  def drained(_state, []), do: :ok

  def drained(state, [first | _] = entries) do
    # A thunk, not a keyword list: `bytes` walks the batch and `state.live.mode`
    # reads the state, so building them eagerly would do that work even when
    # recording is off, and a malformed entry would raise in *this* frame —
    # outside the emitter's rescue.
    inbox(state, :drained, fn ->
      [
        from: Map.get(first, :from),
        kind: Map.get(first, :kind),
        mode: state.live.mode,
        count: length(entries),
        bytes: Enum.sum(Enum.map(entries, &Nest.Timeline.bytes(Map.get(&1, :content)))),
        disposition: state.live.mode
      ]
    end)
  end

  @doc "One `debt` event (`set` / `cleared` / `reminded` / `gave_up`)."
  @spec debt(Agent.t(), atom(), keyword()) :: :ok
  def debt(state, action, fields) do
    record(state, :debt, fn ->
      Map.merge(%{action: action, peer: nil, reminders_used: 0, how: nil}, Map.new(fields))
    end)
  end

  @doc """
  The give-up: one `debt` event per requester the runtime stopped waiting for.

  `how` is the site's reason atom — the same atom the resting funnel was given,
  which is the only place the give-up's *reason* survives — and
  `reminders_used` is that requester's count before the discharge.
  """
  @spec gave_up(Agent.t(), [String.t()], atom()) :: :ok
  def gave_up(state, senders, reason) do
    owed = state.live.machine.owed_replies

    Enum.each(senders, fn peer ->
      debt(state, :gave_up, peer: peer, reminders_used: Map.get(owed, peer, 0), how: reason)
    end)
  end

  @doc """
  A give-up that could not reach its requester, recorded next to the log line
  and the notification `Turn.GiveUpDelivery.log_failure/5` writes.
  """
  @spec give_up_refused(term(), term(), String.t(), term()) :: :ok
  def give_up_refused(space_id, name, peer, why) do
    if Nest.Timeline.enabled?() do
      Nest.Timeline.record(space_id, name, :debt, %{
        action: :give_up_refused,
        peer: peer,
        reminders_used: 0,
        how: refusal(why)
      })
    end

    :ok
  end

  @doc """
  One `tool` event per result, for the tool results the step accepted.

  The event is emitted by the driver (not the pure transition table) because
  recording is an effect, and `worker` is the machine's `active_worker_kind` —
  the worker that produced the batch. `duration_ms` is deliberately absent: the
  worker does not measure per call and the machine has no start stamp, so there
  is no honest value to record.
  """
  @spec tools(Agent.t(), term(), Machine.t()) :: :ok
  def tools(state, {:tool_results, _ref, results}, machine) when is_list(results) do
    Enum.each(results, fn result -> tool(state, result, machine) end)
  end

  def tools(_state, _event, _machine), do: :ok

  defp tool(state, result, machine) do
    record(state, :tool, fn ->
      %{
        name: result.name,
        tool_call_id: result.tool_call_id,
        is_error: result.is_error,
        result_bytes: Nest.Timeline.bytes(result.content),
        worker: machine.work.active_worker_kind
      }
      |> Map.merge(Nest.Timeline.redact("args", result.arguments))
    end)
  end

  @doc """
  One `llm` request line, recorded where the request is dispatched.

  `outcome` is `"sent"`: whether the call succeeded is a later settle and shows
  up as its own `turn` event, so the pair of lines is the record and this one
  does not guess.
  """
  @spec llm_request(Agent.t(), map()) :: :ok
  def llm_request(state, ctx) do
    record(state, :llm, fn ->
      messages = ctx.messages || []
      limit = ctx.context_limit

      %{
        message_index: ctx.next_message_index,
        iteration: state.live.machine.work.iteration,
        model: ctx.client_config.model,
        projected_tokens: ConversationSize.size(messages),
        limit: limit,
        reserve: reserve(limit),
        remaining: remaining(messages, limit),
        outcome: "sent"
      }
    end)
  end

  @doc """
  The `compaction` trigger line, at the point the staged request is dispatched.

  `used` is the request's size and `projected` is that plus the reserve the
  request is allowed to spend (`Budget.fits?/2`'s arithmetic). `trigger` is
  deliberately absent: the reason a compaction was staged is decided in a pure
  module and does not ride the action, so there is no honest value here.
  """
  @spec compaction_staged(Agent.t(), map()) :: :ok
  def compaction_staged(state, ctx) do
    record(state, :compaction, fn ->
      used = ConversationSize.size(ctx.messages || [])

      %{
        limit: ctx.context_limit,
        reserve: reserve(ctx.context_limit),
        used: used,
        projected: used + (reserve(ctx.context_limit) || 0),
        carried: carried(state.live.machine),
        loop_count: state.live.machine.loop_count,
        archived_to_index: nil
      }
    end)
  end

  @doc """
  The `compaction` commit line, recorded once the marker is built.

  `used` is the segment the commit archived and `projected` is the rebuilt
  active segment, so the pair reads as the compaction's before → after.
  """
  @spec compaction_committed(Agent.t(), non_neg_integer(), [term()]) :: :ok
  def compaction_committed(state, archived_to_index, rebuilt) do
    record(state, :compaction, fn ->
      limit = state.llm_metrics.context_limit

      %{
        trigger: "commit",
        limit: limit,
        reserve: reserve(limit),
        used: ConversationSize.size(state.chat_state.messages || []),
        projected: ConversationSize.size(rebuilt || []),
        carried: carried(state.live.machine),
        loop_count: state.live.machine.loop_count,
        archived_to_index: archived_to_index
      }
    end)
  end

  @doc """
  The `usage` line for one LLM response, at the point its totals are folded in.

  The schema's field names are the short ones and the clients' maps use the long
  ones; this is the one place the two are translated.
  """
  @spec usage(Agent.t(), term()) :: :ok
  def usage(state, usage) when is_map(usage) do
    record(state, :usage, fn -> token_fields(usage) end)
  end

  def usage(_state, _usage), do: :ok

  @doc """
  The `usage` line for a child's cost, at the point it is folded into this
  agent's descendant totals. `name` is the child — the event is recorded against
  the parent, which is what owns the totals it lands in.
  """
  @spec child_usage(Agent.t(), String.t(), term()) :: :ok
  def child_usage(state, name, usage) when is_map(usage) do
    record(state, :usage, fn -> Map.put(token_fields(usage), :name, name) end)
  end

  def child_usage(_state, _name, _usage), do: :ok

  @doc """
  A child was spawned. The five spawn-time fields (vocation, depth, model,
  clone_context, archive) exist only here — the child's terminal events cannot
  fill them.
  """
  @spec child_spawned(Agent.t(), String.t(), map() | nil, map()) :: :ok
  def child_spawned(state, name, model, opts) do
    record(state, :child, fn ->
      %{
        action: "spawned",
        name: name,
        vocation: Map.get(opts, :vocation),
        depth: state.depth + 1,
        model: model_name(model),
        clone_context: Map.get(opts, :clone_context, false),
        archive: Map.get(opts, :archive, false)
      }
    end)
  end

  @doc """
  A child's outcome, before it is delivered to its reporting target.

  Only the action and the name are recorded: the executor does not hold the
  spawn-time fields, and reading them back from the child's registry entry would
  be a second source of truth.
  """
  @spec child_message(Agent.t(), String.t(), term()) :: :ok
  def child_message(state, name, result) do
    record(state, :child, fn -> %{action: child_action(result), name: name} end)
  end

  @doc "A child lifecycle action with no result (`archived` / `stopped`)."
  @spec child_action(Agent.t(), String.t(), String.t()) :: :ok
  def child_action(state, action, name) do
    record(state, :child, fn -> %{action: action, name: name} end)
  end

  @doc "The `status` line, carrying the broadcast payload verbatim."
  @spec status(Agent.t(), map()) :: :ok
  def status(state, payload) do
    record(state, :status, fn -> %{payload: payload} end)
  end

  @doc "The `notification` line, next to the broadcast."
  @spec notification(term(), term(), term()) :: :ok
  def notification(space_id, name, payload) do
    if Nest.Timeline.enabled?() do
      Nest.Timeline.record(space_id, name, :notification, %{
        notification_type: field(payload, :type),
        message: field(payload, :message)
      })
    end

    :ok
  end

  @doc """
  The `error` line, next to the broadcast (or the log line when the site only
  logs). `source` is the `[Source: Module.fn/arity]` tag the callers already
  pass.
  """
  @spec error(term(), term(), String.t(), String.t() | nil) :: :ok
  def error(space_id, name, message, source) do
    if Nest.Timeline.enabled?() do
      Nest.Timeline.record(space_id, name, :error, %{message: message, source: source})
    end

    :ok
  end

  # ---- payload building ----

  defp indices(state) do
    for {_role, %{index: index}} <- state.chat_state.messages || [], is_integer(index), do: index
  end

  defp placement(%Machine{kind: kind, phase: phase}), do: %{kind: kind, phase: phase}

  defp reserve(limit) when is_integer(limit) and limit > 0, do: Reserve.compaction_reserve(limit)
  defp reserve(_limit), do: nil

  defp remaining(messages, limit) when is_integer(limit) and limit > 0,
    do: Budget.remaining(messages, limit)

  defp remaining(_messages, _limit), do: nil

  defp token_fields(usage) do
    %{
      input: Map.get(usage, :input_tokens, 0),
      output: Map.get(usage, :output_tokens, 0),
      cache_read: Map.get(usage, :cache_read_input_tokens, 0),
      cache_write: Map.get(usage, :cache_creation_input_tokens, 0),
      total: Map.get(usage, :total_tokens, 0)
    }
  end

  # The carried continuation's tag, or nil for a compaction with nothing to
  # carry. `entry` is a `Machine.entry()` (`{:assistant_response, _, _, _}` …).
  defp carried(%Machine{entry: {:compaction, _staged, nil}}), do: nil

  defp carried(%Machine{entry: {:compaction, _staged, entry}}) when is_tuple(entry),
    do: elem(entry, 0)

  defp carried(_machine), do: nil

  defp child_action({:ok, _response}), do: "completed"
  defp child_action({:failed, _reason}), do: "failed"
  defp child_action({:terminated, _reason}), do: "terminated"
  defp child_action(other), do: inspect(other)

  defp refusal(why), do: GiveUp.failure_reason(why)

  defp model_name(nil), do: nil
  defp model_name(model) when is_binary(model), do: model
  defp model_name(model) when is_map(model), do: Map.get(model, :name) || Map.get(model, "name")
  defp model_name(_model), do: nil

  defp field(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp field(_payload, _key), do: nil

  # ---- recording ----

  defp record(%Agent{} = state, type, payload_fun) do
    if Nest.Timeline.enabled?(), do: safe(state, type, payload_fun), else: :ok
  end

  defp safe(state, type, payload_fun) do
    Nest.Timeline.record(state.space_id, state.name, type, payload_fun.())
  rescue
    error ->
      Logger.warning(
        "Nest.Agents.Agent.Timeline: the #{type} emitter failed " <>
          "(#{Exception.message(error)}); the event was not recorded"
      )

      :ok
  end
end
