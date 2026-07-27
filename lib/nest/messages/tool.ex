defmodule Nest.Messages.Tool do
  @moduledoc """
  Tool response message. Carries `Part.ToolResult` structs
  (one per tool call that completed in the LLM's batch).
  """

  alias Nest.Messages.Message
  alias Nest.Messages.Part

  defstruct [:index, :parts, :timestamp, :metadata, :api_logs, :tokens]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          parts: [Part.ToolResult.t()],
          timestamp: DateTime.t() | nil,
          metadata: map() | nil,
          api_logs: [map()] | nil,
          tokens: non_neg_integer() | nil
        }

  @doc """
  Convert to JSON-compatible map for wire format.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = msg) do
    %{
      "index" => msg.index,
      "role" => "tool",
      "parts" => Enum.map(msg.parts, &Part.to_json/1),
      "apiLogs" => Message.format_api_logs(msg.api_logs)
    }
    |> Message.maybe_put_tokens(msg.tokens)
  end
end
