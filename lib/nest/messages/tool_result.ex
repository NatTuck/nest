defmodule Nest.Messages.ToolResult do
  @moduledoc """
  A single tool execution result.

  `state` is the optional word for a result that is not a verdict at all:
  `"backgrounded"` is the machine's synthetic answer to a call *it* moved to the
  background (issue #36), and `"waiting"` is a wait tool's own answer for a call
  that registered a watch (`agents-wait`/`shell-wait`, issue #54). Both mean the
  same thing to a reader — the call's real result arrives later as a message —
  and they are distinct because the reason differs. See
  `Nest.Messages.Part.ToolResult`, which this struct becomes, for what a reader
  does with a value it does not know.
  """

  defstruct [:tool_call_id, :name, :content, :arguments, :is_error, :state]

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          name: String.t(),
          content: String.t(),
          arguments: map() | nil,
          is_error: boolean(),
          state: String.t() | nil
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
    |> maybe_put_state(tr.state)
  end

  # Absent and `nil` are the same thing to every reader of this shape, so the
  # key is omitted rather than written as null — the same rule
  # `Nest.Messages.Part.to_json/1` applies to its optional keys.
  defp maybe_put_state(map, nil), do: map
  defp maybe_put_state(map, state), do: Map.put(map, "state", state)
end
