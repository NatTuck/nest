defmodule Nest.Agents.Agent.Machine.Boundary do
  @moduledoc """
  The turn-boundary inbox-delivery decision (issue #15).

  Split out of `Nest.Agents.Agent.Machine.Transitions` for the same reason
  `Machine.Compaction` and `Machine.Response` are: the transition table is at
  the credo source-file cap. This module owns one decision and nothing else —
  whether `Transitions.iterate/1` delivers queued inbox entries before
  starting the next request, or dispatches it as usual.

  ## The rule

  Deliver when all of these hold:

    1. `ctx.inbox_count` is a positive integer (see `inbox_count/1`),
    2. `work.force_finalize` is false, and
    3. the transcript tail is a `{:tool, _}` or `{:assistant, _}` message.

  Condition 2 keeps `force_finalize`'s "wrap this turn up now" meaning: at the
  `:overflow_tool_calls` and `refuse_mixed` boundaries the machine has just
  appended synthetic tool results and asked the model for a final answer, so
  the queued message waits for the turn end.

  Condition 3 reads the message *tag*, and `MessageList.last_wire_role/1` is
  not usable for it: that function maps `{:tool, _}` to `:user` (a tool message
  is a user-role message on the wire), and the tool tail is exactly the case we
  want to deliver into. The tag check also excludes the just-opened-turn shape,
  where the machine itself just appended the tail (a turn opening, including
  `Compaction.resume/1`'s `resume_with_pending/1` path).

  The caller reaches this only from the `[]` branch of
  `MessageList.unpaired_tail_tool_uses/1`, and that position is load-bearing: a
  `{:assistant, _}` tail can still carry unanswered `Part.ToolUse` (a carried
  `{:tool_call, assistant, …}` compaction continuation, which is reachable
  mid-turn), and appending a user message onto one would be refused by `Repair`
  and fail the turn. Requiring the unpaired list to be empty closes that hole;
  the tag check then only has to exclude the just-opened-turn shape.

  The `{:assistant, _}` tail itself is defensive today: every `:iterate` site
  was enumerated and none reaches it with an unpaired-free assistant tail (a
  carried tool call preflights, a carried assistant response finalizes instead
  of iterating, the truncation/silent re-prompt nudges with a user message).
  It is kept because the drain is the right disposition for that shape:
  without it `Transitions.dispatch_http/1` would ship an assistant tail and
  `Preflight.validate_request/1` would fail the turn on
  `:no_trailing_assistant`.

  `Transitions` emits `[{:drain_inbox}]` and returns the machine unchanged, so
  the phase stays `:generating` and the executor's follow event starts the
  delivered message's turn in place — no transient `:idle` is ever broadcast.
  """

  alias Nest.Agents.Agent.Machine

  @doc """
  Whether `Transitions.iterate/1` delivers queued inbox entries instead of
  dispatching the next request. Valid only from the `[]` branch of
  `MessageList.unpaired_tail_tool_uses/1` — see the moduledoc.
  """
  @spec drain?(Machine.t()) :: boolean()
  def drain?(m) do
    inbox_count(m.work.ctx) > 0 and not m.work.force_finalize and
      deliverable_tail?(List.last(m.work.ctx.messages))
  end

  # `Turn.build_ctx/2` always sets `inbox_count` from `length(state.live.inbox)`;
  # the 0 default only covers the tests that hand-build a `ctx` map, where
  # "nothing queued" is the intended state. Guarded with `is_integer/1` because
  # `nil > 0` is true in Erlang term order.
  defp inbox_count(%{inbox_count: n}) when is_integer(n), do: n
  defp inbox_count(_ctx), do: 0

  defp deliverable_tail?({tag, _msg}) when tag in [:tool, :assistant], do: true
  defp deliverable_tail?(_last), do: false
end
