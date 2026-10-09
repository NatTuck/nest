defmodule Nest.Agents.Agent.SubAgentResults do
  @moduledoc """
  The text a sub-agent's outcome becomes, built in one place.

  `child_message/2` is the §2.1 delivery: a child's outcome enqueued into the
  parent's own inbox, as the child's own words when it produced content and as a
  runtime notice otherwise. `bound/3` caps an unbounded sub-agent result (a
  child's or peer's text) to the per-call inline budget, offloading the full
  text to the agent scratch dir when it doesn't fit — the same summarization
  path `BatchSizer` and `BatchPlan` use, and what `agents-wait` returns through.
  """

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.CapCalculator
  alias Nest.Agents.Agent.Inbox
  alias Nest.Messages.ToolCall
  alias Nest.Tokens.Estimator

  # -- the parent's inbox --

  @doc """
  The inbox message a child's outcome arrives as, and the kind that frames it
  (issue #31 §2.1). A completion is the child's own words — `kind: :agent`, so
  `Inbox.combine/1` labels it `[Message from agent "<name>"]` — while a child
  that produced nothing, failed, or was stopped is the *runtime* speaking
  (`kind: :notice`, rendered bare), because the child did not say it (decision
  9's instinct). An answer is bounded by the inbox's own offload cap when it is
  delivered, so nothing is capped here.
  """
  @spec child_message(String.t(), term()) :: {String.t(), Inbox.kind()}
  def child_message(_name, {:ok, response}) when is_binary(response) and response != "",
    do: {response, :agent}

  def child_message(name, {:ok, _empty}),
    do: {"Child agent #{name} finished its turn without producing any text.", :notice}

  def child_message(name, {:failed, reason}),
    do: {"Child agent #{name} failed before it answered: #{inspect(reason)}", :notice}

  def child_message(name, {:terminated, reason}),
    do: {"Child agent #{name} was stopped before it answered: #{inspect(reason)}", :notice}

  # -- bounding --

  @doc """
  Bound an unbounded sub-agent result to the per-call inline cap. Sub-agent
  tools bypass `BatchSizer`, so this is where their results get an
  in-budget substitute: if the response exceeds `max_result_tokens`, the
  full text is written to the agent scratch dir and a pointer + head is
  returned inline.
  """
  @spec bound(String.t(), ToolCall.t(), map()) :: String.t()
  def bound(content, %ToolCall{} = tc, %{context_limit: limit, messages: _} = ctx)
      when is_integer(limit) and limit > 0 do
    usable = CapCalculator.usable_remaining(ctx)

    if usable > 0 and
         Estimator.estimate(content) > CapCalculator.effective_max_result_tokens(tc, usable) do
      budget = CapCalculator.effective_max_result_tokens(tc, usable)
      Overflow.substitute(content, ctx, sub_label(tc), budget, "agents")
    else
      content
    end
  end

  def bound(content, _tc, _ctx), do: content

  defp sub_label(%ToolCall{name: name}), do: "Output of #{name}"
end
