defmodule Nest.Agents.Agent.Turn.Backgrounded do
  @moduledoc """
  Delivery of a backgrounded batch's outcome (issue #36, step 2).

  A batch is *backgrounded* when a message arrives while it is executing:
  the machine moves it out of `worker_ref`/`active_worker`, records it in
  `Machine.Work.backgrounded`, and keeps the turn going. Its eventual
  result — or its worker's death — has no live worker to settle, so the
  machine clears the entry and emits
  `{:deliver_backgrounded, ref, outcome, fulfilled_ids}` (the ref answers
  exactly once), and the executor runs it: `Inbox.enqueue_runtime/3` renders
  the outcome here as a `:runtime` entry, and the fulfilled ids ride the
  entry onto the message the drain appends, so a later load can tell a promise
  that was kept from one the process died with.

  `:runtime` is the only honest kind (no agent said this), and it renders
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
  load heal (`Repair.classify_load/2`) appends the record instead.

  ## Segments, and the invariant that keeps the model's text unchanged

  A notice is not one string but a sequence of segments (`parts/1`), because the
  command's *output* has to reach the browser as output — the client renders a
  user row as markdown, which mangles `#`, `*`, `_`, backticks and indented
  lines (issue #139) — while the prose around it stays prose. Each segment is
  `{:text, String.t()}` or `{:output, String.t()}`; the output segments are what
  the client is told to render verbatim (`Nest.Messages.User.command_output_metadata/1`).

  **`notice/1` is exactly the join of `parts/1`'s texts**
  (`notice(outcome) == outcome |> parts() |> Enum.map_join("", &elem(&1, 1))`).
  That is the invariant that makes this split provably a display change: every
  consumer of the notice — the entry's `content`, the drain's rendering, the
  model's prompt — sees the same bytes it saw before segments existed. Do not
  give either function its own wording; derive one from the other.
  """

  alias Nest.Messages.Segment

  # `ShellCmd.handle_timeout/3` appends this to stderr, which the combined
  # result content carries. The number in it is the tool's own bound.
  @timeout_marker "[Command timed out after"

  @doc """
  Render a backgrounded batch's outcome as ordered segments: the prose the model
  reads, and the command output it reads verbatim.

  `{:results, results}` is the batch's result list (the same
  `ToolResult` structs a foreground batch would append);
  `{:worker_down, reason}` is a backgrounded worker that died before it
  delivered anything.

  Each result contributes the sentence the notice has always carried
  (`"Your backgrounded command (name) finished. Its result:"`, or the
  `timed out. Its output so far:` variant keyed off the command's own timeout
  marker) followed by its content as an `:output` segment; results are separated
  by a blank line, as they always were. A worker's death is one `:text` segment,
  because there is no output to show.

  The concatenation of every segment's text is `notice/1`'s output, byte for
  byte — that is this function's contract, and the reason splitting the notice
  changed nothing the model reads.
  """
  @spec parts({:results, [term()]} | {:worker_down, term()}) :: [Segment.t()]
  def parts({:results, results}) do
    results
    |> Enum.map(&result_parts/1)
    |> Segment.separate()
  end

  def parts({:worker_down, reason}) do
    [
      {:text,
       "A backgrounded tool call stopped before it finished (#{inspect(reason)}), " <>
         "so its result will not arrive. Call it again if you still need it."}
    ]
  end

  @doc """
  Render a backgrounded batch's outcome as the notice text.

  Exactly `parts/1`'s texts joined with no separator. `enqueue_runtime/3` builds
  the entry's `content` from `parts/1` itself rather than calling this (so the
  two cannot drift), and `combine_and_offload/2` renders from segments for the
  same reason; this function is the invariant's statement and the oracle the
  tests hold it to.
  """
  @spec notice({:results, [term()]} | {:worker_down, term()}) :: String.t()
  def notice(outcome), do: outcome |> parts() |> Enum.map_join("", &elem(&1, 1))

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

  defp result_parts(%{name: name, content: content}) do
    # `to_string/1` keeps `Segment.t/0`'s contract true: the old wording
    # interpolated the content (`"…\n\n#{content}"`), which coerced it, and a
    # segment's text reaches the wire as a `Part.Text`, where a non-binary would
    # be a malformed row rather than a coerced one.
    [{:text, result_prose(name, content)}, {:output, to_string(content)}]
  end

  # The sentence, with the blank line that has always separated it from the
  # output it introduces. The separator rides the prose segment rather than the
  # output one so the output segment is exactly the command's own bytes.
  defp result_prose(name, content) do
    if timed_out?(content) do
      "Your backgrounded command (#{name}) timed out. Its output so far:\n\n"
    else
      "Your backgrounded command (#{name}) finished. Its result:\n\n"
    end
  end

  # The blank line between results: `Nest.Messages.Segment.separate/1` puts it on
  # each result's *last* segment (its output), so the next result's prose starts
  # a paragraph of its own — and the final result carries none, exactly as the
  # old `Enum.map_join(results, "\n\n", …)` did.
  defp timed_out?(content) when is_binary(content),
    do: String.contains?(content, @timeout_marker)

  defp timed_out?(_content), do: false
end
