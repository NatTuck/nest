defmodule Nest.Agents.Agent.SubAgentResults do
  @moduledoc """
  The text of a sub-agent tool result, built in one place.

  Both the blocking path (`Nest.Agents.Agent.ToolLoop`) and the async
  delivery path (`Nest.Agents.Agent.AsyncWaiter`) use these builders, so
  the body an async waiter delivers is exactly the content the blocking
  path would have returned as the tool result for the same outcome — the
  two cannot drift.

  `bound/3` caps an unbounded sub-agent result (a child's or peer's text)
  to the per-call inline budget, offloading the full text to the agent
  scratch dir when it doesn't fit — the same summarization path
  `BatchSizer` and `BatchLoop` use.
  """

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.CapCalculator
  alias Nest.Messages.ToolCall
  alias Nest.Tokens.Estimator

  # -- agents-spawn --

  @doc """
  The blocking path's content for a completed child. A child that
  finished its turn without any text must not come back as a successful
  empty result: say so explicitly instead (the caller marks that case as
  an error).
  """
  @spec spawn_completed(map(), ToolCall.t(), String.t(), String.t()) :: String.t()
  def spawn_completed(_ctx, _tc, spawned_name, "") do
    "Child agent #{spawned_name} finished its turn without producing any text."
  end

  def spawn_completed(ctx, tc, _spawned_name, response), do: bound(response, tc, ctx)

  @doc "The blocking path's content for a child that failed."
  @spec spawn_child_failed(String.t(), term()) :: String.t()
  def spawn_child_failed(spawned_name, reason),
    do: "Child agent #{spawned_name} failed: #{inspect(reason)}"

  @doc "The blocking path's content for a child that did not finish in time."
  @spec spawn_timeout() :: String.t()
  def spawn_timeout, do: "Child agent did not complete in time."

  # -- agents-query --

  @doc "The blocking path's content for a peer's successful reply."
  @spec query_success(map(), ToolCall.t(), String.t()) :: String.t()
  def query_success(ctx, tc, content), do: bound(content, tc, ctx)

  @doc "The blocking path's content for a failed peer query."
  @spec query_failure(term(), String.t()) :: String.t()
  def query_failure({:timeout, timeout}, target),
    do: "Could not query #{target}: timed out after #{timeout}ms waiting for its turn to finish."

  def query_failure(:no_text, target),
    do: "Could not query #{target}: it finished its turn without producing any text."

  def query_failure({:read_failed, reason}, target),
    do: "Could not query #{target}: could not read its messages: #{inspect(reason)}"

  def query_failure({:chat, reason}, target),
    do: "Could not query #{target}: #{inspect(reason)}"

  def query_failure({:not_found, reason}, target),
    do: "Agent #{target} not found in this space: #{inspect(reason)}"

  # Fallback for an unexpected tag: never crash the waiter (or the tool
  # worker) over an unhandled reason — report it as a plain failure.
  def query_failure(reason, target), do: "Could not query #{target}: #{inspect(reason)}"

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

  defp sub_label(%ToolCall{name: "agents-query"}), do: "Response from agents-query"
  defp sub_label(%ToolCall{name: "agents-spawn"}), do: "Response from agents-spawn"
  defp sub_label(%ToolCall{name: name}), do: "Output of #{name}"
end
