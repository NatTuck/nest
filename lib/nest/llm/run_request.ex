defmodule Nest.LLM.RunRequest do
  @moduledoc """
  Inputs to a single LLM completion.

  Carries the canonical Nest message history (with the immutable
  initial system message at position 0 and any late system reminders
  at later positions), the tool spec list, and a handful of model-
  and provider-level knobs. The client (OpenAI, Anthropic, or a mock)
  is responsible for serializing this into a wire-format request.
  """

  defstruct messages: [],
            tools: [],
            model: nil,
            tool_choice: :auto,
            temperature: nil,
            max_tokens: nil,
            top_p: nil,
            stream: true,
            metadata: nil

  @type tool_choice :: :auto | :none | :required | {:tool, String.t()}

  @type t :: %__MODULE__{
          messages: [Nest.Messages.Message.t()],
          tools: [Nest.LLM.Tool.t()],
          model: String.t() | nil,
          tool_choice: tool_choice(),
          temperature: float() | nil,
          max_tokens: integer() | nil,
          top_p: float() | nil,
          stream: boolean(),
          metadata: map() | nil
        }
end
