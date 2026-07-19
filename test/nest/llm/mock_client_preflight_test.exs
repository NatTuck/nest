defmodule Nest.LLM.MockClientPreflightTest do
  @moduledoc """
  Confirms that `Nest.LLM.MockClient.run/2` surfaces preflight
  failures (unpaired tool calls / tool results) through the
  canonical event stream as an Anthropic-shaped 400 error.

  Existing tests would otherwise drift past the bug — adding
  this single test exposes the contract that `MockClient.run/2`
  emits the same `{kind, status, body}` shape the real
  `AnthropicClient` produces for this error class.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.MockClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  setup do
    MockClient.start_link()
    MockClient.clear()
    on_exit(fn -> MockClient.stop() end)
    :ok
  end

  test "unpaired tool_use/tool_call_id surfaces an Anthropic-parody 400 error" do
    req = %RunRequest{
      model: "test",
      messages: [
        {:assistant,
         %Assistant{parts: [%Part.ToolUse{id: "a", name: "shell_cmd", arguments: %{}}]}},
        {:tool,
         %Tool{
           parts: [
             %Part.ToolResult{
               tool_call_id: "b",
               name: "shell_cmd",
               content: "ok",
               is_error: false
             }
           ]
         }}
      ]
    }

    {:ok, stream} = MockClient.run(req)
    events = Enum.to_list(stream)

    assert {:error, {"request_failed", 400, body}} = hd(events)

    assert body["type"] == "error"
    assert body["error"]["type"] == "bad_request_error"
    assert body["error"]["message"] =~ "tool call result does not follow tool call"

    details = body["error"]["details"]
    assert is_list(details)
    assert Enum.any?(details, &(&1.kind == :missing_tool_responses and &1.missing_ids == ["a"]))
    assert Enum.any?(details, &(&1.kind == :orphan_tool_result and &1.orphan_ids == ["b"]))

    assert Enum.at(events, 1) == {:done, %{response: %RunResponse{stop_reason: "stop"}}}
  end
end
