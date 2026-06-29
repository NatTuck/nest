defmodule Nest.Messages.System do
  @moduledoc "System message with configuration/instructions"

  alias Nest.Messages.Message
  alias Nest.Messages.Part

  defstruct [:index, :parts, :timestamp, :metadata, :api_logs]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          parts: [Part.t()],
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
      "role" => "system",
      "parts" => Enum.map(msg.parts, &Part.to_json/1),
      "mode" => msg.metadata && msg.metadata["mode"],
      "apiLogs" => Message.format_api_logs(msg.api_logs)
    }
  end
end
