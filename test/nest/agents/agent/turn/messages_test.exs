defmodule Nest.Agents.Agent.Turn.MessagesTest do
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Turn.Messages
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall

  test "assistant/1 orders thinking before text and tool_use" do
    # Anthropic (and DeepSeek's Anthropic-compatible endpoint) require
    # the `thinking` block to lead an assistant message's content array.
    response = %RunResponse{
      model: "m",
      text: "visible",
      thinking: "reasoning",
      thinking_signature: "sig",
      tool_calls: [%ToolCall{id: "c1", name: "shell-cmd", arguments: %{}}]
    }

    {:assistant, assistant} = Messages.assistant(response)

    assert Enum.map(assistant.parts, & &1.__struct__) == [
             Part.Thinking,
             Part.Text,
             Part.ToolUse
           ]
  end

  test "assistant/1 omits thinking when the response carried none" do
    response = %RunResponse{model: "m", text: "visible"}

    {:assistant, assistant} = Messages.assistant(response)

    assert Enum.map(assistant.parts, & &1.__struct__) == [Part.Text]
  end
end
