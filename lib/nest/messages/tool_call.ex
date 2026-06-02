defmodule Nest.Messages.ToolCall do
  @moduledoc "A tool call requested by the assistant"

  defstruct [:id, :name, :arguments]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map()
        }

  @doc """
  Convert to JSON-compatible map for wire format.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = tc) do
    %{
      "id" => tc.id,
      "name" => tc.name,
      "arguments" => tc.arguments
    }
  end
end
