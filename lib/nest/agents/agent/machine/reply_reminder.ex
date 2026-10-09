defmodule Nest.Agents.Agent.Machine.ReplyReminder do
  @moduledoc """
  The reply gate (issue #31 §1.5): the one place that decides whether a turn
  that would rest must first remind the agent that it still owes a reply.

  A turn cannot end while the agent owes a peer an answer, so the runtime either
  keeps the turn alive with one reminder or rests and gives the debt up
  (`Machine.GiveUp`, through the resting funnel). Two sites would otherwise rest
  with the debt standing, and both ask this module:

    * `Machine.Response.finalize_or_defer/4` — a final reply that fits the
      content budget;
    * `Machine.Compaction.resume/1` — a reply carried across a compaction, which
      the commit put in the active segment.

  Both do the same two things with the answer: remind (append the reminder and
  continue the turn) or rest. `:settle` is not a decision to drop the debt — the
  rest it leads to is the funnel's, and the funnel gives it up.

  ## Only the debts that are due, and each only once

  The reminder names the senders whose *own* budget is unspent
  (`Machine.due_senders/1`), and counts only those
  (`Machine.count_reminders/2`). A sender whose reminder was already sent is not
  named again: with `%{"alice" => 1, "bob" => 0}` the reminder names bob alone,
  so alice's spent budget cannot be re-armed by a query that arrived later
  (decision 10 — the budget is per debt, and the runtime gives up on the debts
  it can no longer remind).
  """

  alias Nest.Agents.Agent.Machine
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Tokens.Budget
  alias Nest.Tokens.Estimator

  @doc """
  Decide whether a would-be rest must remind first.

  `projected` is the message list the reminder would be appended to, with the
  caller's own pending append already in it: the gate sizes the reminder against
  what the model would actually see.

  Returns `{:remind, text, machine}` — with the reminder counted against the due
  senders — or `:settle`, meaning the runtime can no longer remind and the rest
  gives the debt up.
  """
  @spec decision(Machine.t(), [term()] | nil) :: {:remind, String.t(), Machine.t()} | :settle
  def decision(machine, projected \\ nil) do
    projected = projected || own_messages(machine)

    case Machine.due_senders(machine) do
      [] ->
        :settle

      senders ->
        text = text(senders)

        if fits?(machine, projected, text) and appendable?(List.last(projected)) do
          {:remind, text, Machine.count_reminders(machine, senders)}
        else
          :settle
        end
    end
  end

  @doc """
  The reminder's text: it names the debtors and nothing else.

  No quote of the outstanding message (decision 4 — the agent looks that up in
  its own inbox), no sender label and no mode prefix: the runtime is not a peer,
  and the reminder is worded so it cannot read as one.
  """
  @spec text([String.t()]) :: String.t()
  def text([sender]) do
    "You have not answered agent \"#{sender}\" yet. Its query is in your " <>
      "inbox above — send your reply now with the `agents-send` tool."
  end

  def text(senders) do
    named = Enum.map_join(senders, ", ", &"agent \"#{&1}\"")

    "You have not answered #{named} yet. Their queries are in your inbox " <>
      "above — send your replies now with the `agents-send` tool."
  end

  # The machine's own active message list. A hand-built fixture may carry no
  # turn context at all; with nothing projected there is nothing the reminder
  # would be appended to, so the fit check has no limit to test.
  defp own_messages(%{work: %{ctx: %{messages: messages}}}) when is_list(messages), do: messages
  defp own_messages(_machine), do: []

  # The fit guard, copied from `nudge_or_finalize/2`: a reminder that does not
  # fit the remaining budget is not injected. A machine with no context limit
  # always has room.
  defp fits?(machine, projected, text) do
    limit = machine.work.ctx.context_limit

    not (is_integer(limit) and limit > 0) or
      Budget.remaining(projected, limit) >= Estimator.estimate(text)
  end

  # A user message appended onto an assistant message that still carries an
  # unanswered `tool_use` is refused by `Repair.classify_live/2` — and that
  # refusal fails the turn. `:force_finalize` is classified before the
  # tool-call branches, so the wrap-up second chance can still come back with
  # tool calls; the gate is only legal when the projected tail is not such a
  # reply. Only the tail matters: the carried-reply site commits an assistant
  # tail the same way, and a tool result `Turn.Commit` appended after it is a
  # legal place for a user message.
  defp appendable?({:assistant, %Assistant{parts: parts}}), do: no_tool_use?(parts)
  defp appendable?(_other), do: true

  defp no_tool_use?(nil), do: true
  defp no_tool_use?(parts), do: not Enum.any?(parts, &match?(%Part.ToolUse{}, &1))
end
