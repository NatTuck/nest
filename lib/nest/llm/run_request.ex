defmodule Nest.LLM.RunRequest do
  @moduledoc """
  Inputs to a single LLM completion.

  Carries the canonical Nest message history, the tool spec list, and a
  handful of model- and provider-level knobs. The client (OpenAI,
  Anthropic, or a mock) is responsible for serializing this into a
  wire-format request.
  """

  defstruct messages: [],
            tools: [],
            model: nil,
            # Provider-agnostic system prompt. Anthropic puts this at
            # the top of the request body; OpenAI prepends it as a
            # `system` message in the messages array. Clients must
            # *not* also look for a leading `{:system, _}` message
            # in `messages` — that convention is removed.
            system_prompt: nil,
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
          system_prompt: String.t() | nil,
          tool_choice: tool_choice(),
          temperature: float() | nil,
          max_tokens: integer() | nil,
          top_p: float() | nil,
          stream: boolean(),
          metadata: map() | nil
        }
end
