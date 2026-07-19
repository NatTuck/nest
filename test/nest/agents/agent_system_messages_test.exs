defmodule Nest.Agents.AgentSystemMessagesTest do
  @moduledoc """
  Integration tests for the system-message flow: the initial
  `{:system, _}` message at position 0 of `state.chat_state.messages`,
  and the budget-remaining notice injected into tool responses.

  The budget reminder is now attached to the `{:tool, _}` message
  as a `Part.Text` prefix rather than being injected as a separate
  system message.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: SystemMsg

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "initial system message" do
    test "the agent's messages list always starts with a {:system, _} message" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      state = :sys.get_state(pid)
      first = hd(state.chat_state.messages)

      assert match?({:system, %SystemMsg{}}, first)
    end

    test "the empty system message is in state (transparency)" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      messages = Nest.Agents.Agent.get_messages(pid)

      assert {:system, %SystemMsg{parts: [%Part.Text{text: ""}]}} = hd(messages)
    end
  end

  describe "budget reminder attached to tool response" do
    test "the budget warning is attached as Part.Text in the tool message" do
      for i <- 1..4 do
        MockClient.set_tool_response(%{
          text: "loop #{i}",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      MockClient.set_response("All done, used tools 4 times")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      capture_log(fn ->
        :ok = Agent.chat(pid, "Loop until done")
        assert_receive {:chat_status, %{status: "idle"}}, 5000
      end)

      state = :sys.get_state(pid)

      tool_messages =
        Enum.filter(state.chat_state.messages, fn
          {:tool, _} -> true
          _ -> false
        end)

      texts =
        Enum.flat_map(tool_messages, fn {:tool, %Nest.Messages.Tool{parts: parts}} ->
          Enum.filter(parts, &match?(%Part.Text{}, &1))
        end)

      assert texts != []
      text = hd(texts)
      assert text.text =~ "tool call rounds remaining"
    end

    test "the budget reminder and the final response get distinct indices (regression: dual-counter bug)" do
      for i <- 1..4 do
        MockClient.set_tool_response(%{
          text: "loop #{i}",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      MockClient.set_response("All done, used tools 4 times")

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      capture_log(fn ->
        :ok = Agent.chat(pid, "Loop until done")
        assert_receive {:chat_status, %{status: "idle"}}, 5000
      end)

      state = :sys.get_state(pid)

      tool_messages =
        Enum.filter(state.chat_state.messages, fn
          {:tool, _} -> true
          _ -> false
        end)

      # At least one tool message has a notice text
      texts =
        Enum.flat_map(tool_messages, fn {:tool, %Nest.Messages.Tool{parts: parts}} ->
          Enum.filter(parts, &match?(%Part.Text{}, &1))
        end)

      assert texts != []

      # The final assistant has a different index from the
      # tool messages (regression: dual-counter bug).
      {:assistant, final} = List.last(state.chat_state.messages)

      {:tool, last_tool} =
        tool_messages
        |> List.last()

      assert final.index != last_tool.index,
             "final assistant (#{final.index}) and tool (#{last_tool.index}) share an index"
    end
  end
end
