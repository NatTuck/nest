defmodule Nest.Messages.Assistant do
  @moduledoc "Assistant message that can contain text, thinking, or tool calls"

  alias Nest.Messages.Message
  alias Nest.Messages.ToolCall

  defstruct [
    :index,
    :content,
    :thinking,
    :thinking_signature,
    :tool_calls,
    :refusal,
    :timestamp,
    :metadata,
    :api_logs
  ]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          content: String.t() | nil,
          thinking: String.t() | nil,
          # Anthropic's extended-thinking signature, which must be
          # echoed back on subsequent turns so the model can verify
          # the prior reasoning block. `nil` for providers that
          # don't emit one (OpenAI reasoning models emit `thinking`
          # text only).
          thinking_signature: String.t() | nil,
          tool_calls: [ToolCall.t()] | nil,
          refusal: String.t() | nil,
          timestamp: DateTime.t() | nil,
          # Free-form bag for client-specific data. Known keys today:
          # none — clients with provider-specific payloads should
          # add named fields to this struct rather than reach into
          # metadata.
          metadata: map() | nil,
          api_logs: [map()] | nil
        }

  @doc """
  Convert to JSON-compatible map for wire format.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = msg) do
    %{
      "index" => msg.index,
      "role" => "assistant",
      "content" => msg.content || "",
      "toolCalls" => format_tool_calls(msg.tool_calls),
      "toolResults" => nil,
      "thinking" => msg.thinking,
      "thinkingSignature" => msg.thinking_signature,
      "apiLogs" => Message.format_api_logs(msg.api_logs),
      "metadata" => stringify_metadata(msg.metadata)
    }
  end

  # The wire format uses string keys everywhere. Convert atom
  # keys in `metadata` (e.g. `:stopped_by_user` would become
  # `"stopped_by_user"` if we ever set it as such) and pass
  # string-keyed maps through unchanged. `nil` becomes `nil`.
  defp stringify_metadata(nil), do: nil

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {k, v} -> {if(is_atom(k), do: Atom.to_string(k), else: k), v} end)
  end

  defp format_tool_calls(nil), do: nil
  defp format_tool_calls([]), do: nil

  defp format_tool_calls(tool_calls) do
    Enum.map(tool_calls, &ToolCall.to_json/1)
  end
end
