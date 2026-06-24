defmodule Nest.Agents.Agent.ChatTurn.HelpersTest do
  @moduledoc """
  Unit tests for `Nest.Agents.Agent.ChatTurn.Helpers`.

  These helpers own the LLM-loop end-of-iteration dispatch:
  injecting budget reminders as system messages, and building
  the synthetic-error tool pair for the second-chance call.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatTurn.Helpers
  alias Nest.Agents.Agent.LLMRunner
  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall

  defp ctx(agent_pid \\ self()) do
    %LLMRunner.RunContext{agent_id: "test-agent", agent_pid: agent_pid}
  end

  defp state(message_index) do
    %LLMRunner.RunState{message_index: message_index}
  end

  describe "maybe_inject_budget_warning/4" do
    test "returns messages unchanged when remaining is greater than 2" do
      messages = [{:user, :stub}]
      assert Helpers.maybe_inject_budget_warning(messages, ctx(), 3, self()) == messages
      assert Helpers.maybe_inject_budget_warning(messages, ctx(), 5, self()) == messages
    end

    test "returns messages unchanged when remaining is 0 or negative" do
      messages = [{:user, :stub}]
      assert Helpers.maybe_inject_budget_warning(messages, ctx(), 0, self()) == messages

      assert Helpers.maybe_inject_budget_warning(messages, ctx(), -1, self()) ==
               messages
    end

    test "appends a '2 rounds left' reminder when remaining is 2 and sends it to the pid" do
      messages = [{:user, :stub}]
      result = Helpers.maybe_inject_budget_warning(messages, ctx(), 2, self())

      assert {:system, %System{content: content}} = List.last(result)
      assert content =~ "2 tool call rounds remaining"
      assert length(result) == 2

      # The reminder is also sent to the GenServer pid for broadcast + persist
      assert_receive {:system_reminder_received, {:system, %System{content: sent_content}}},
                     100

      assert sent_content == content
    end

    test "appends a 'last round' reminder when remaining is 1" do
      messages = [{:user, :stub}]
      result = Helpers.maybe_inject_budget_warning(messages, ctx(), 1, self())

      assert {:system, %System{content: content}} = List.last(result)
      assert content =~ "last tool call round"
    end

    test "works without a pid (pure data, no broadcast)" do
      messages = [{:user, :stub}]
      result = Helpers.maybe_inject_budget_warning(messages, ctx(), 1, nil)

      assert length(result) == 2
      assert {:system, _} = List.last(result)
      refute_receive _, 50
    end
  end

  describe "build_tool_pair/3" do
    test "returns the assistant + tool result triple with response fields" do
      response = %Nest.LLM.RunResponse{
        text: "I'm calling a tool",
        thinking: "thinking about it",
        tool_calls: [
          %ToolCall{id: "call_1", name: "shell_cmd", arguments: %{"command" => "ls"}}
        ],
        thinking_signature: "sig"
      }

      {tool_call_message, tool_result_message, appended} =
        Helpers.build_tool_pair(ctx(), state(5), response)

      assert {:assistant, %Assistant{}} = tool_call_message
      assert {:tool, %Tool{}} = tool_result_message

      assert tool_call_message
             |> elem(1)
             |> Map.get(:content) == "I'm calling a tool"

      assert tool_call_message |> elem(1) |> Map.get(:thinking) == "thinking about it"
      # appended = ctx.messages (empty) ++ [tool_call, tool_result] = 2 entries
      assert length(appended) == 2
    end
  end

  describe "build_synthetic_error_pair/3" do
    test "produces an assistant + error tool result triple for each LLM tool call" do
      response = %Nest.LLM.RunResponse{
        text: "I tried to call more tools",
        tool_calls: [
          %ToolCall{id: "c1", name: "shell_cmd", arguments: %{"command" => "ls"}},
          %ToolCall{id: "c2", name: "read_file", arguments: %{"path" => "/tmp"}}
        ]
      }

      {tool_call_message, tool_result_message, appended} =
        Helpers.build_synthetic_error_pair(ctx(), state(7), response)

      assert {:assistant, %Assistant{tool_calls: calls}} = tool_call_message
      assert length(calls) == 2

      assert {:tool, %Tool{tool_results: results}} = tool_result_message
      assert length(results) == 2
      assert Enum.all?(results, & &1.is_error)

      for result <- results do
        assert result.content =~ "Maximum tool iterations reached"
      end

      assert length(appended) == 2
    end

    test "handles the case where the LLM emitted no tool calls (empty list)" do
      response = %Nest.LLM.RunResponse{text: "no calls", tool_calls: []}

      {_, tool_result_message, appended} =
        Helpers.build_synthetic_error_pair(ctx(), state(0), response)

      assert {:tool, %Tool{tool_results: []}} = tool_result_message
      assert length(appended) == 2
    end
  end
end
