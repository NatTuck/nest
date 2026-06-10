defmodule Nest.Messages.ToolResult do
  @moduledoc "A single tool execution result"

  defstruct [:tool_call_id, :name, :content, :arguments, :is_error]

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          name: String.t(),
          content: String.t(),
          arguments: map() | nil,
          is_error: boolean()
        }

  @doc """
  Convert to JSON-compatible map for wire format.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = tr) do
    %{
      "tool_call_id" => tr.tool_call_id,
      "name" => tr.name,
      "content" => tr.content,
      "arguments" => tr.arguments || %{},
      "is_error" => tr.is_error || false
    }
  end
end
