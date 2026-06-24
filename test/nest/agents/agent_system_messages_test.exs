defmodule Nest.Agents.AgentSystemMessagesTest do
  @moduledoc """
  Integration tests for the system-message flow: the initial
  `{:system, _}` message at position 0 of `state.chat_state.messages`,
  and the late system reminders injected by the LLM runner when
  the agent is approaching the tool-iteration cap.

  Extracted from `agent_chat_test.exs` (where it was becoming
  cluttered) so the chat-flow file stays under the 500-line
  credo limit.
  """

  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.System
  alias Nest.Test.TaskDrain

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    on_exit(fn -> TaskDrain.drain() end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "initial system message" do
    test "the agent's messages list always starts with a {:system, _} message" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      state = :sys.get_state(pid)
      first = hd(state.chat_state.messages)

      assert match?({:system, %System{}}, first)
    end

    test "when the system prompt is empty, the empty system message is in state but not broadcast" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      state = :sys.get_state(pid)
      assert {:system, %System{content: ""}} = hd(state.chat_state.messages)

      MockClient.set_response("Hello back")
      :ok = Agent.chat(pid, "Hi")

      # The empty system message is in state but was NOT broadcast
      # (would render as an empty chat bubble). The chat_status
      # transition to idle is the proof the chat completed.
      assert_receive {:chat_status, %{status: "idle"}}, 1000
      refute_receive {:chat_message, {:system, _}}, 100
    end
  end

  describe "late system reminder (budget warning)" do
    test "the budget warning is injected as a system message, not appended to the system_prompt" do
      # Set up the runner to approach the iteration cap. With
      # `max-tool-iterations = 5` and one tool call per
      # response, on the 4th tool call response the runner
      # has `remaining = 2` and should inject a reminder.
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

        # We expect at least one late system reminder mid-stream.
        # The reminder's content matches "2 tool call rounds remaining"
        # (injected when remaining goes from 3 to 2).
        assert_receive {:chat_message, {:system, %System{content: content}}}, 2000
        assert content =~ "tool call rounds remaining"
      end)
    end

    test "the budget reminder is persisted in state.chat_state.messages" do
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

      MockClient.set_response("All done")

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      capture_log(fn ->
        :ok = Agent.chat(pid, "Loop until done")
        # Wait for the chat to finish.
        _ = :sys.get_state(pid)
        Process.sleep(200)
      end)

      state = :sys.get_state(pid)

      system_messages =
        Enum.filter(state.chat_state.messages, fn
          {:system, %System{}} -> true
          _ -> false
        end)

      # At least the initial system message + at least one
      # budget reminder. The reminder is in the messages list
      # in order (transparency — what the LLM saw is what
      # the agent shows).
      assert length(system_messages) >= 2
    end
  end
end
