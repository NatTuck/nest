defmodule Nest.Agents.Agent.Turn.Backgrounded do
  @moduledoc """
  Delivery of a backgrounded batch's outcome (issue #36, step 2).

  A batch is *backgrounded* when a message arrives while it is executing:
  the machine moves it out of `worker_ref`/`active_worker`, records it in
  `Machine.Work.backgrounded`, and keeps the turn going. Its eventual
  result — or its worker's death — has no live worker to settle, so the
  machine clears the entry and emits
  `{:deliver_backgrounded, ref, outcome, fulfilled_ids}` (the ref answers
  exactly once), and the executor runs it: `Inbox.deliver_notice/3` renders
  the outcome here as a runtime `:notice`, and the fulfilled ids ride the
  entry onto the message the drain appends, so a later load can tell a promise
  that was kept from one the process died with.

  `:notice` is the only honest kind (no agent said this), and it renders
  bare — no `[Message from agent …]` label would be truthful (issue #31
  decision 9).

  The wording keys off the command's own timeout marker (decision D4): a
  timed-out command's result is error-shaped and carries
  `[Command timed out after Nms]` in its content, so the notice says the
  command timed out rather than that it finished. `handle_timeout/3` and
  the result tuple shape are deliberately untouched — the marker is the
  whole contract.

  It also owns the **cancellation** wording: a backgrounded call killed by a
  Stop never reports a result, so the stop appends the runtime's cancellation
  notice and the assistant's acknowledgement of it (`cancellation/1`, issue
  #36 step 4) instead of waiting for one.

  And the **loss** wording (`lost/1`): a promise the process died with. The
  batch's entry lives in the machine, so a restart or an archive drops it, and
  a restored transcript would keep promising a result that can never come. The
  load heal (`Repair.classify_load/1`) appends the record instead.
  """

  # `ShellCmd.handle_timeout/3` appends this to stderr, which the combined
  # result content carries. The number in it is the tool's own bound.
  @timeout_marker "[Command timed out after"

  @doc """
  Render a backgrounded batch's outcome as the notice text.

  `{:results, results}` is the batch's result list (the same
  `ToolResult` structs a foreground batch would append);
  `{:worker_down, reason}` is a backgrounded worker that died before it
  delivered anything.
  """
  @spec notice({:results, [term()]} | {:worker_down, term()}) :: String.t()
  def notice({:results, results}), do: Enum.map_join(results, "\n\n", &result_text/1)

  def notice({:worker_down, reason}) do
    "A backgrounded tool call stopped before it finished (#{inspect(reason)}), " <>
      "so its result will not arrive. Call it again if you still need it."
  end

  @doc """
  The cancellation record's wording for `count` backgrounded calls killed by a
  Stop (issue #36, step 4): the runtime's notice, then the assistant's
  acknowledgement of it.

  A killed call's result can never arrive, so the notice says so rather than
  leaving the model waiting on a promise the stop has voided. Both strings are
  count-aware because the machine writes one record for the whole stop
  (`Machine.Stopping`): the entry carries the batch's call count, not per-call
  identity, so the count is what tells the model how many promises the stop
  voided.
  """
  @spec cancellation(pos_integer()) :: {String.t(), String.t()}
  def cancellation(1) do
    {"The tool call that was running in the background was cancelled when the " <>
       "conversation was stopped; its result will not arrive.",
     "Understood. I will not wait for it."}
  end

  def cancellation(count) when is_integer(count) and count > 1 do
    {"The #{count} tool calls that were running in the background were cancelled " <>
       "when the conversation was stopped; their results will not arrive.",
     "Understood. I will not wait for them."}
  end

  @doc """
  The load-time record for a promise the *restart* voided: a transcript restored
  with a backgrounded call still in it, whose batch died with the process that
  owned it.

  Count-aware for the same reason `cancellation/1` is (one record covers every
  promise the heal found), and it names the remedy — the call can be made again
  — because nothing else in the transcript can: the synthetic result says the
  real one "will arrive later as a message", and after a restart it never will.
  """
  @spec lost(pos_integer()) :: {String.t(), String.t()}
  def lost(1) do
    {"The backgrounded tool call was lost when this agent restarted; its result " <>
       "will not arrive. Call it again if you still need it.",
     "Understood. I will not wait for it."}
  end

  def lost(count) when is_integer(count) and count > 1 do
    {"The #{count} backgrounded tool calls were lost when this agent restarted; " <>
       "their results will not arrive. Call them again if you still need them.",
     "Understood. I will not wait for them."}
  end

  defp result_text(%{name: name, content: content}) do
    if timed_out?(content) do
      "Your backgrounded command (#{name}) timed out. Its output so far:\n\n#{content}"
    else
      "Your backgrounded command (#{name}) finished. Its result:\n\n#{content}"
    end
  end

  defp timed_out?(content) when is_binary(content),
    do: String.contains?(content, @timeout_marker)

  defp timed_out?(_content), do: false
end
