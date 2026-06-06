defmodule Nest.Messages.Assistant do
  @moduledoc "Assistant message that can contain text, thinking, or tool calls"

  alias Nest.Messages.Message
  alias Nest.Messages.ToolCall

  defstruct [:index, :content, :thinking, :tool_calls, :refusal, :timestamp, :metadata, :api_logs]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          content: String.t() | nil,
          thinking: String.t() | nil,
          tool_calls: [ToolCall.t()] | nil,
          refusal: String.t() | nil,
          timestamp: DateTime.t() | nil,
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
      "apiLogs" => Message.format_api_logs(msg.api_logs)
    }
  end

  defp format_tool_calls(nil), do: nil
  defp format_tool_calls([]), do: nil

  defp format_tool_calls(tool_calls) do
    Enum.map(tool_calls, &ToolCall.to_json/1)
  end
end
