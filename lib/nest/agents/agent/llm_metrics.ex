defmodule Nest.Agents.Agent.LlmMetrics do
  @moduledoc """
  LLM call metrics and the resolved context limit. Lives in a
  sub-struct so the `Agent` struct stays focused on identity
  and configuration.
  """
  defstruct context_limit: nil,
            context_limit_source: nil,
            usage_totals: nil
end
