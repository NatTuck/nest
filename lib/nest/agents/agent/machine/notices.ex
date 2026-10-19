defmodule Nest.Agents.Agent.Machine.Notices do
  @moduledoc """
  The two notice transitions: a space-environment change and a model change.

  Both are the same shape — a runtime pair appended when the conversation can
  hold it, carried on a compaction's entry when it needs one, and refused with the
  overflow banner when nothing can help — and they differ only in the pair's body
  and in the reason the resting funnel records. `Machine.Transitions` keeps the
  `do_step/2` clauses (one line each, so the dispatch table's order stays visible
  in one place) and this module holds their bodies.

  Pure, like the rest of the transition table: no effect, and no machine field
  written outside `Machine.Phase`.

  The notice rides the *event*, not the machine: its lifetime is one settle (or
  the compaction that settle stages — see `Compaction.stage/3`), so there is no
  slot for it to outlive. `work.pending_notice` is the iteration-budget reminder's
  alone, and `Phase.rest/4` is the whole rest, so no field of another feature's is
  cleared on the way out.
  """

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Compaction
  alias Nest.Agents.Agent.Machine.Phase
  alias Nest.Agents.Agent.ModelHandler
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Agents.Agent.WorkspaceHandler

  @doc """
  Apply a notice event to an `:idle` machine.

  `Machine.Transitions` is the only caller, and it has already matched the phase
  and the event's payload; the tag decides which pair to build and which reason
  the resting funnel records.
  """
  @spec step(Machine.t(), :workspace_notice | :model_notice, map()) ::
          {:ok, [Machine.action()], Machine.t()}
  def step(m, :workspace_notice, values) do
    pair = WorkspaceHandler.notice_pair(values, m.work.ctx.mode)

    case decision(m, pair) do
      :fits ->
        Phase.rest(m, :chat, :workspace_notice, [{:append_many, pair}, {:drain_inbox}])

      :needs_compaction ->
        # The notice rides the compaction's entry, so only the compaction that
        # staged it can append it, and a failure drops it with the entry.
        Compaction.stage(m, nil, values)

      :cannot_compact ->
        Phase.block(m, :context_overflow, :workspace_notice, [overflow()])
    end
  end

  # The agent's model changed. Its prompt states the model's name, its image-input
  # verdict and the context limit it budgets against, and is never rebuilt (prefix
  # cache), so this pair is the only place that can correct them.
  def step(m, :model_notice, facts) do
    pair = ModelHandler.notice_pair(facts, m.work.ctx.mode)

    case decision(m, pair) do
      :fits ->
        Phase.rest(m, :chat, :model_notice, [{:append_many, pair}, {:drain_inbox}])

      :needs_compaction ->
        Compaction.stage(m, nil, facts)

      :cannot_compact ->
        Phase.block(m, :context_overflow, :model_notice, [overflow()])
    end
  end

  # Whether the conversation can hold the pair, needs a compaction to hold it, or
  # can hold it no way at all — the same three answers every delivered message
  # gets.
  defp decision(m, pair) do
    Dispatch.preflight_decision(m.work.ctx.messages ++ pair, m.work.ctx.context_limit)
  end

  # A notice that cannot fit and cannot be compacted for blocks instead of being
  # appended into an oversized request. The same banner for both notices.
  defp overflow,
    do: {:broadcast, {:overflow, :reserve_exhausted, "start a conversation"}, nil}
end
