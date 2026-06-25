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

    test "the empty system message is in state AND is broadcast (transparency)" do
      # The empty system message is broadcast during
      # `init/1`, so we need to subscribe to the PubSub
      # topic BEFORE the agent starts. Pre-compute the id
      # and use `start_supervised!/1` directly instead of
      # the `start_agent/1` helper (which generates the id
      # internally). We don't need MockClient here — we're
      # only verifying the broadcast happens during init,
      # not running a chat turn.
      agent_id = "transparency-agent-#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      pid =
        start_supervised!({Agent, %{id: agent_id, model: %{name: "qwen3.5-plus"}}})

      # The empty system message is broadcast so the UI can
      # render a placeholder (per the AGENTS.md transparency
      # rule: the UI always includes everything that
      # happened). Hiding it server-side would violate the
      # principle. Regression guard.
      assert_receive {:chat_message, {:system, %SystemMsg{content: ""}}}, 1000

      # And it's still in state.
      state = :sys.get_state(pid)
      assert {:system, %SystemMsg{content: ""}} = hd(state.chat_state.messages)
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
        assert_receive {:chat_message, {:system, %SystemMsg{content: content}}}, 2000
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

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      capture_log(fn ->
        :ok = Agent.chat(pid, "Loop until done")
        # Wait for the chat to finish. The Agent broadcasts
        # `chat:status: idle` on every finalization (after
        # the budget reminder has been persisted).
        assert_receive {:chat_status, %{status: "idle"}}, 2000
      end)

      state = :sys.get_state(pid)

      system_messages =
        Enum.filter(state.chat_state.messages, fn
          {:system, %SystemMsg{}} -> true
          _ -> false
        end)

      # At least the initial system message + at least one
      # budget reminder. The reminder is in the messages list
      # in order (transparency — what the LLM saw is what
      # the agent shows).
      assert length(system_messages) >= 2
    end

    test "the budget reminder and the final response get distinct indices (regression: dual-counter bug)" do
      # Regression guard for the disappearing-reminder bug.
      # Before the Agent was the sole writer of `index`, the
      # budget reminder (stamped at `next_message_index` by
      # the Agent) shared the same index as the next LLM
      # response (predicted by the LLMRunner's `+ 2` math
      # from `state.message_index`). React's `key={message.index}`
      # would reuse the same DOM node, and the JS
      # `addChatMessage` merge would overwrite the reminder
      # with the response. After PR 1 the Agent stamps every
      # message at the next free slot, so the reminder and
      # the response are at distinct indices and both are
      # visible in the UI.
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

        # The reminder is broadcast.
        assert_receive {:chat_message,
                        {:system, %SystemMsg{index: reminder_index, content: content}}},
                       2000

        assert content =~ "tool call rounds remaining"

        # The final response is broadcast at a different index.
        # Before the fix, both would share the same index.
        assert_receive {:chat_message, {:assistant, %{index: response_index}}}, 2000

        assert response_index != reminder_index,
               "reminder (index #{reminder_index}) and response (index #{response_index}) share an index — dual-counter bug"
      end)
    end
  end
end
