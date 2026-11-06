defmodule Nest.Agents.Agent.SubAgentResults do
  @moduledoc """
  The text a sub-agent's outcome becomes, built in one place.

  `child_message/2` is the §2.1 delivery: a child's outcome enqueued into the
  parent's own inbox, as the child's own words when it produced content and as a
  runtime notice otherwise. `bound/3` caps an unbounded sub-agent result (a
  child's or peer's text) to the per-call inline budget, offloading the full
  text to the agent scratch dir when it doesn't fit — the same summarization
  path `BatchSizer` and `BatchPlan` use.
  """

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.ResultPolicy
  alias Nest.Messages.ToolCall

  # -- the parent's inbox --

  @doc """
  The inbox message a child's outcome arrives as, and the kind that frames it
  (issue #31 §2.1). A completion is the child's own words — `kind: :agent`, so
  its body is headered `[From agent <name> | mode: …]` — while a child that
  produced nothing, failed, or was stopped is the *runtime* speaking
  (`kind: :runtime`, headered `[From nest runtime | mode: …]`), because the
  child did not say it (decision 9's instinct). An answer is bounded by the
  inbox's own offload cap when it is delivered, so nothing is capped here.
  """
  @spec child_message(String.t(), term()) :: {String.t(), Inbox.kind()}
  def child_message(_name, {:ok, response}) when is_binary(response) and response != "",
    do: {response, :agent}

  def child_message(name, {:ok, _empty}),
    do: {"Child agent #{name} finished its turn without producing any text.", :runtime}

  def child_message(name, {:failed, reason}),
    do: {"Child agent #{name} failed before it answered: #{inspect(reason)}", :runtime}

  def child_message(name, {:terminated, reason}),
    do: {"Child agent #{name} was stopped before it answered: #{inspect(reason)}", :runtime}

  # -- bounding --

  @doc """
  Bound an unbounded sub-agent result. Sub-agent tools bypass `BatchSizer`, so
  this is where their results meet the same admission: over
  `min(requested, budget)`, the full text is written to the agent scratch dir
  and a pointer + preview comes back inline.
  """
  @spec bound(String.t(), ToolCall.t(), map()) :: String.t()
  def bound(content, %ToolCall{} = tc, %{context_limit: limit} = ctx)
      when is_integer(limit) and limit > 0 do
    case decision(content, tc, ctx) do
      {:inline, _size} -> content
      {:file, size} -> substitute(content, tc, ctx, size)
      {:refuse, size} -> refusal(tc, ctx, size)
    end
  end

  def bound(content, _tc, _ctx), do: content

  defp decision(content, tc, ctx) do
    ResultPolicy.admit(content, inline(tc, ctx), ResultPolicy.on_over(tc.name))
  end

  defp inline(tc, ctx), do: ResultPolicy.limit(tc, budget(ctx))

  defp refusal(tc, ctx, size), do: ResultPolicy.refusal(size, inline(tc, ctx), tc.name)

  defp budget(ctx) do
    case ResultPolicy.window(ctx) do
      {:ok, left} -> left
      :none -> 0
    end
  end

  defp substitute(content, tc, ctx, size) do
    case Overflow.substitute(content, ctx, ResultPolicy.label(tc.name), "agents") do
      {:ok, pointer} -> pointer
      :error -> ResultPolicy.offload_failure(size)
    end
  end
end
