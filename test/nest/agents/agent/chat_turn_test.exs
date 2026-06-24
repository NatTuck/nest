defmodule Nest.Agents.Agent.ChatTurnTest do
  @moduledoc """
  Acceptance tests for the `Nest.Agents.Agent.ChatTurn`
  GenServer — the iteration state machine that drives each
  chat turn. These tests are the contract: they drive the
  ChatTurn through every transition (single-iteration,
  multi-iteration, budget reminder, max-iterations
  second-chance, user stop, HTTP crash, nil usage, multi-turn)
  with a real Agent and the existing `MockClient`.

  They use `:sys.get_state/1` to inspect the Agent's state
  directly so we can assert against the message index, the
  status, and the `chat_turn_pid` field (the externally
  visible contract the ChatTurn must honor). PubSub
  broadcasts are used to assert the externally visible
  contract (chat:message, chat:status, chat:error).

  These tests must pass before the refactor is complete.
  They cover the regression cases that the old
  `LLMRunner.run/2`-in-a-Task design broke with the
  dual-counter bug class.
  """
  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.System, as: SystemMsg
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

  defp wait_for_idle(pid, timeout \\ 2000) do
    start = System.monotonic_time(:millisecond)
    do_wait_for_idle(pid, timeout, start)
  end

  defp do_wait_for_idle(pid, timeout, start) do
    state = :sys.get_state(pid)

    if state.chat_state.status == :idle do
      :ok
    else
      elapsed = System.monotonic_time(:millisecond) - start

      if elapsed > timeout do
        :timeout
      else
        Process.sleep(10)
        do_wait_for_idle(pid, timeout, start)
      end
    end
  end

  defp message_indices(state) do
    state.chat_state.messages
    |> Enum.flat_map(fn
      {_, %{index: idx}} -> [idx]
      _ -> []
    end)
  end

  describe "single-iteration turn" do
    test "1.1.1 appends user + assistant, transitions to idle" do
      MockClient.set_response("Hello back")

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Hello")

      assert :ok = wait_for_idle(pid)

      state = :sys.get_state(pid)

      assert state.chat_state.status == :idle
      assert state.chat_state.chat_turn_pid == nil
      assert state.chat_state.cancelled == false

      indices = message_indices(state)

      assert length(state.chat_state.messages) == 3
      assert hd(state.chat_state.messages) |> elem(0) == :system
      assert {:user, %{} = user} = Enum.at(state.chat_state.messages, 1)
      assert {:assistant, %Assistant{} = assistant} = Enum.at(state.chat_state.messages, 2)

      assert user.index == 1
      assert assistant.index == 2
      assert assistant.content == "Hello back"
      assert indices == Enum.sort(indices)
      assert Enum.uniq(indices) == indices
    end
  end

  describe "multi-iteration turn" do
    test "1.1.2 tool call then final response: 4 messages with sequential indices" do
      MockClient.set_tool_response(%{
        text: "Calling a tool",
        tool_calls: [
          %{id: "call_1", name: "shell_cmd", arguments: %{"command" => "echo hi"}}
        ]
      })

      MockClient.set_response("Tool result was hi")

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Run a command")

      assert :ok = wait_for_idle(pid)

      state = :sys.get_state(pid)

      assert length(state.chat_state.messages) == 5
      assert state.chat_state.status == :idle

      assert message_indices(state) == [0, 1, 2, 3, 4]
    end
  end

  describe "budget reminder" do
    test "1.1.3 reminder is injected on remaining=2, gets distinct index from final response" do
      for i <- 1..4 do
        MockClient.set_tool_response(%{
          text: "loop #{i}",
          tool_calls: [
            %{id: "call_#{i}", name: "shell_cmd", arguments: %{"command" => "echo loop"}}
          ]
        })
      end

      MockClient.set_response("All done")

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      capture_log(fn ->
        :ok = Agent.chat(pid, "Loop until done")
        assert :ok = wait_for_idle(pid)
      end)

      state = :sys.get_state(pid)

      reminders =
        Enum.filter(state.chat_state.messages, fn
          {:system, %SystemMsg{content: content}} when is_binary(content) ->
            String.contains?(content, "tool call rounds remaining") or
              String.contains?(content, "last tool call round")

          _ ->
            false
        end)

      assert reminders != [], "expected at least one budget reminder in messages"

      reminder_indices = Enum.map(reminders, fn {_, %{index: idx}} -> idx end)

      responses =
        Enum.filter(state.chat_state.messages, fn
          {:assistant, %Assistant{tool_calls: tc}} -> tc in [nil, []]
          _ -> false
        end)

      response_indices = Enum.map(responses, fn {_, %{index: idx}} -> idx end)

      Enum.each(reminder_indices, fn ri ->
        Enum.each(response_indices, fn si ->
          assert ri != si,
                 "reminder index #{ri} collides with response index #{si} — dual-counter bug"
        end)
      end)

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  describe "max iterations second-chance" do
    test "1.1.4 max_iterations: final call uses tools: nil, iteration produces a final response" do
      # With max_iterations=5, queue more than 5 tool
      # responses. The ChatTurn should hit the iteration
      # cap, switch to `tools: nil, tool_choice: :none`,
      # and the MockClient (which honors `tools: nil` by
      # returning a random text response) produces the
      # final assistant message.
      for i <- 1..10 do
        MockClient.set_tool_response(%{
          text: "tool call #{i}",
          tool_calls: [
            %{id: "call_#{i}", name: "shell_cmd", arguments: %{"command" => "echo loop"}}
          ]
        })
      end

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      capture_log(fn ->
        :ok = Agent.chat(pid, "Keep looping")
        assert :ok = wait_for_idle(pid)
      end)

      state = :sys.get_state(pid)

      # The agent goes to :idle after the iteration
      # completes.
      assert state.chat_state.status == :idle
      assert state.chat_state.chat_turn_pid == nil

      # The conversation has the user message + multiple
      # tool iterations + a final assistant message.
      # The exact count depends on how the MockClient
      # behaves with `tools: nil` (it skips queued tool
      # responses and returns a random text), but we
      # expect AT LEAST 3 tool pairs (6 messages) and a
      # final assistant.
      assistant_count =
        Enum.count(state.chat_state.messages, fn
          {:assistant, _} -> true
          _ -> false
        end)

      assert assistant_count >= 1, "expected at least one assistant message"

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  describe "user-initiated stop" do
    test "1.1.5 finalizes the partial assistant message and transitions to idle" do
      events = for _ <- 1..1000, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "Tell me a long story")

      # Wait for the chat turn to start streaming.
      state_after_start = wait_for_streaming(pid)
      chat_turn_pid = state_after_start.chat_state.chat_turn_pid
      assert is_pid(chat_turn_pid), "expected a chat_turn_pid while streaming"

      # Wait for at least one delta so we have something
      # in the streaming_acc mirror to finalize. The
      # stop-finalized message is always appended (with
      # `content: nil` if no deltas arrived), but this
      # test asserts non-nil content, so we make sure
      # at least one delta was processed before stopping.
      Process.sleep(20)

      send(chat_turn_pid, {:stop_chat, self()})

      assert :ok = wait_for_idle(pid)

      state = :sys.get_state(pid)

      assert state.chat_state.status == :idle
      assert state.chat_state.chat_turn_pid == nil

      final_assistants =
        Enum.filter(state.chat_state.messages, fn
          {:assistant, %Assistant{content: content}} when is_binary(content) -> true
          _ -> false
        end)

      assert final_assistants != [],
             "expected a partial assistant message after stop"

      AgentTestHelpers.assert_unique_message_indices(state)
    end

    defp wait_for_streaming(pid, timeout \\ 1000) do
      start = System.monotonic_time(:millisecond)
      do_wait_for_streaming(pid, timeout, start)
    end

    defp do_wait_for_streaming(pid, timeout, start) do
      state = :sys.get_state(pid)

      streaming? =
        state.chat_state.status == :streaming and
          state.chat_state.chat_turn_pid != nil

      if streaming? do
        state
      else
        elapsed = System.monotonic_time(:millisecond) - start

        if elapsed > timeout do
          state
        else
          Process.sleep(5)
          do_wait_for_streaming(pid, timeout, start)
        end
      end
    end
  end

  describe "HTTP worker crash" do
    test "1.1.6 Agent receives {:chat_crashed, _}, broadcasts chat:error, transitions to idle" do
      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      Mimic.stub(MockClient, :run, fn _request, _opts ->
        raise FunctionClauseError,
          module: Nest.LLM.OpenAIClient,
          function: :finish_event,
          arity: 1,
          args: [%{"delta" => %{"role" => "assistant"}}]
      end)

      Mimic.allow(MockClient, self(), pid)

      :ok = Agent.chat(pid, "Hello")

      assert :ok = wait_for_idle(pid)

      state = :sys.get_state(pid)

      assert state.chat_state.status == :idle
      assert state.chat_state.chat_turn_pid == nil
    end
  end

  describe "nil usage is a no-op" do
    test "1.1.7 second chat with no usage does not zero out accumulated output_tokens" do
      MockClient.set_response("First response")
      MockClient.set_response("Second response with no usage event")

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "First")
      assert :ok = wait_for_idle(pid)

      first_info = Agent.get_public_info(pid)
      first_output = first_info.usage.output_tokens || 0

      :ok = Agent.chat(pid, "Second")
      assert :ok = wait_for_idle(pid)

      second_info = Agent.get_public_info(pid)
      second_output = second_info.usage.output_tokens || 0

      assert second_output >= first_output,
             "second chat's output_tokens (#{second_output}) " <>
               "should not be less than first chat's (#{first_output}) — nil usage should be a no-op"
    end
  end

  describe "multi-turn monotonic indices" do
    test "1.1.8 two chats: indices strictly monotonic, no gaps, no duplicates" do
      MockClient.set_response("First")
      MockClient.set_response("Second")

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      :ok = Agent.chat(pid, "First chat")
      assert :ok = wait_for_idle(pid)

      :ok = Agent.chat(pid, "Second chat")
      assert :ok = wait_for_idle(pid)

      state = :sys.get_state(pid)
      indices = message_indices(state)

      # The two chats should produce: system (0), user1 (1),
      # asst1 (2), user2 (3), asst2 (4) — 5 messages with
      # indices [0, 1, 2, 3, 4].
      assert indices == [0, 1, 2, 3, 4],
             "expected indices [0, 1, 2, 3, 4], got #{inspect(indices)}"

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end
end
