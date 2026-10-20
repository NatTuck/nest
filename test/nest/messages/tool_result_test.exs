defmodule Nest.Messages.ToolResultTest do
  @moduledoc """
  Pin tests for `Nest.Messages.ToolResult.to_json/1` — the raw result shape
  `BatchSizer` builds before `Turn.Messages` turns it into a
  `Part.ToolResult`.

  The one optional key is `state`: a result that is not a verdict carries it
  (a wait tool's `"waiting"`, a backgrounded batch's `"backgrounded"`), and a
  result a tool produced does not — an absent key and a `nil` are the same
  thing to every reader of this shape, so the key is omitted rather than
  written as null.
  """
  use ExUnit.Case, async: true

  alias Nest.Messages.ToolResult

  test "emits the wire keys, and the optional state only when there is one" do
    plain = %ToolResult{tool_call_id: "c", name: "shell-cmd", content: "ok", is_error: false}
    json = ToolResult.to_json(plain)

    assert json["tool_call_id"] == "c"
    assert json["name"] == "shell-cmd"
    assert json["content"] == "ok"
    assert json["arguments"] == %{}
    refute Map.has_key?(json, "state")

    waiting = %{plain | state: "waiting", is_error: nil}
    json = ToolResult.to_json(waiting)

    assert json["state"] == "waiting"
    assert json["is_error"] == false
  end
end
