defmodule Nest.Messages.User do
  @moduledoc "User message with text content"

  alias Nest.Messages.Message

  defstruct [:index, :content, :timestamp, :metadata, :api_logs]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          content: String.t(),
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
      "role" => "user",
      "content" => msg.content,
      "mode" => msg.metadata && msg.metadata["mode"],
      "toolCalls" => nil,
      "toolResults" => nil,
      "thinking" => nil,
      "apiLogs" => Message.format_api_logs(msg.api_logs)
    }
  end
end
