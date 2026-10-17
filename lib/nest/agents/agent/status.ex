defmodule Nest.Agents.Agent.Status do
  @moduledoc """
  Executor for the `agents-status` tool (issue #22).

  Reports what `agents-history` needs in order to be used correctly — how many
  messages the target's history holds (and so the valid index range), the index
  of its last compaction, and its current state — plus the rest of what is
  cheap and honest to report about it: its model, vocation and depth, and, when
  it has a live process, the replies it owes, how many messages are queued in
  its inbox, and its context limit.

  The durable fields come from the target's row (space-scoped by
  `Nest.Agents.Agent.History.Target`, which also refuses an archived agent) and
  the live fields from `Nest.Agents.Agent.get_public_info/2`. The live read
  resolves through `Nest.Agents.Supervisor.get_running_agent/2`, never
  `get_agent/2`: a status query must not start the agent it is only observing,
  so an agent with no process is reported as `not_running` rather than as an
  idle one, and a registered pid that does not answer the read is reported as
  `unknown` rather than as a state.

  The message count is the row's `next_message_index` — the persisted mirror of
  the runtime counter, and so the count of rows in the history `agents-history`
  reads. Reporting that number rather than the in-memory one is deliberate: the
  index range this tool reports is the range a history read can actually serve.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.History.Target
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.Supervisor
  alias Nest.Messages.ToolCall
  alias Nest.Vocations

  # The live read is a call into another process. Bounded so a target that does
  # not answer inside it is reported as unresponsive rather than holding this
  # worker (and its caller's turn).
  @call_timeout 5_000

  @doc """
  Run one `agents-status` call. Returns `{:ok, content}` (the report) or
  `{:error, content}` for a missing target or an archived one.
  """
  @spec run(map(), ToolCall.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(ctx, %ToolCall{} = tc) do
    with {:ok, name, row} <- Target.resolve(ctx, tc) do
      {:ok, render(name, row, live(ctx.space_id, name))}
    end
  end

  # The target's public info when it has a live process, `:not_running` when it
  # has none, or `:unresponsive` when a registered pid did not answer the read
  # (it died in between, or it is wedged past the call's bound). A non-answer is
  # not a status — the same rule `AgentTestLifecycle`'s probe follows — so the
  # two are reported differently instead of a wedged process reading as stopped.
  defp live(space_id, name) do
    case Supervisor.get_running_agent(space_id, name) do
      {:ok, pid} -> Agent.get_public_info(pid, @call_timeout)
      {:error, :not_found} -> :not_running
    end
  catch
    :exit, _reason -> :unresponsive
  end

  defp render(name, %PersistedAgent{} = row, live) do
    count = row.next_message_index

    lines = [
      "Agent \"#{name}\": #{status_line(live)}",
      messages_line(count),
      compaction_line(row.last_compaction_index),
      "  model: #{inspect(row.model)}",
      "  vocation: #{vocation(row.vocation_id)}",
      "  depth: #{row.depth}"
    ]

    Enum.join(lines ++ live_lines(live), "\n")
  end

  defp status_line(:not_running), do: "not_running (no live process)"

  defp status_line(:unresponsive),
    do: "unknown (the live process did not answer a status read)"

  defp status_line(%{status: status}), do: "#{status} (running)"

  # The index range is stated because it is exactly what a range read accepts;
  # a row with no messages has no range to state.
  defp messages_line(0), do: "  messages: 0"
  defp messages_line(count), do: "  messages: #{count} (indices 0..#{count - 1})"

  # `-1` is the boundary sentinel for "never compacted", not an index that
  # exists, so it is spelled out rather than left for the reader to know.
  defp compaction_line(-1), do: "  last compaction index: -1 (never compacted)"
  defp compaction_line(index), do: "  last compaction index: #{index}"

  # One row, not the whole table: this is a single id's slug. A row that is gone
  # (a dangling `vocation_id`) is reported as what it is rather than as a slug.
  defp vocation(vocation_id) do
    case Vocations.get_vocation(vocation_id) do
      nil -> "unknown (id #{inspect(vocation_id)})"
      vocation -> vocation.slug
    end
  end

  # A live-only field is reported as unknown when there is no process to ask,
  # never omitted: the reader must be able to tell "nothing owed" from "not
  # observable".
  defp live_lines(:not_running), do: unknown_lines("no live process")

  defp live_lines(:unresponsive), do: unknown_lines("the live process did not answer")

  defp live_lines(%{
         owed_replies: owed_replies,
         pending_message_count: pending,
         context_limit: limit
       }) do
    [
      "  owed replies: #{owed(owed_replies)}",
      "  pending inbox: #{pending} message(s)",
      "  context limit: #{limit}"
    ]
  end

  defp unknown_lines(why) do
    [
      "  owed replies: unknown (#{why})",
      "  pending inbox: unknown (#{why})",
      "  context limit: unknown (#{why})"
    ]
  end

  defp owed([]), do: "none"
  defp owed(senders) when is_list(senders), do: Enum.join(senders, ", ")
end
