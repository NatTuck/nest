defmodule Nest.Messages.Tool do
  @moduledoc "Tool result message from executed tool(s)"

  alias Nest.Messages.Message
  alias Nest.Messages.ToolResult

  defstruct [:index, :tool_results, :timestamp, :metadata, :api_logs]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          tool_results: [ToolResult.t()],
          timestamp: DateTime.t() | nil,
          metadata: map() | nil,
          api_logs: [map()] | nil
        }

  @doc """
  Convert to JSON-compatible map for wire format.
  Tool messages contain a list of tool results.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = msg) do
    formatted_results = Enum.map(msg.tool_results, &ToolResult.to_json/1)

    %{
      "index" => msg.index,
      "role" => "tool",
      "content" => nil,
      "toolCalls" => nil,
      "toolResults" => formatted_results,
      "thinking" => nil,
      "apiLogs" => Message.format_api_logs(msg.api_logs)
    }
  end
end
