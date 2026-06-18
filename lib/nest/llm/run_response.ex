defmodule Nest.LLM.RunResponse do
  @moduledoc """
  Aggregated result of a single LLM completion.

  Carries the visible text, the thinking/reasoning text (when emitted),
  the decoded tool calls, optional usage stats, and a stop reason
  normalized to a string the agent can log and translate.
  """

  defstruct text: nil,
            thinking: nil,
            thinking_signature: nil,
            tool_calls: [],
            refusal: nil,
            usage: nil,
            stop_reason: nil,
            model: nil,
            metadata: nil

  @type usage :: %{
          prompt_tokens: non_neg_integer(),
          completion_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          reasoning_tokens: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          text: String.t() | nil,
          thinking: String.t() | nil,
          thinking_signature: String.t() | nil,
          tool_calls: [Nest.Messages.ToolCall.t()],
          refusal: String.t() | nil,
          usage: usage() | nil,
          stop_reason: String.t() | nil,
          model: String.t() | nil,
          metadata: map() | nil
        }

  @doc """
  True when the response contains tool calls the agent should execute.
  """
  @spec has_tool_calls?(t()) :: boolean()
  def has_tool_calls?(%__MODULE__{tool_calls: calls}) when is_list(calls) do
    calls != []
  end
end
