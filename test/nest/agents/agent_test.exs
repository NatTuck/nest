defmodule Nest.Agents.AgentTest do
  @moduledoc """
  Tests for the Agent GenServer.
  """
  use ExUnit.Case, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Registry

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    # Registry is already started by Application
    :ok
  end

  defp start_agent(attrs \\ %{}) do
    defaults = %{
      id: "test-agent-#{System.unique_integer([:positive])}",
      # Use a model that exists in test/data/config.toml
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }

    attrs = Map.merge(defaults, attrs)
    start_supervised!({Agent, attrs})
  end

  describe "start_link/1" do
    test "starts agent with initial state" do
      pid = start_agent(%{id: "test-agent", model: %{name: "qwen3.5-plus"}})
      state = Agent.get_state(pid)
      assert state.id == "test-agent"
      assert state.status == :idle
      assert state.messages == []
      assert state.model.name == "qwen3.5-plus"
    end

    test "registers agent in registry" do
      pid = start_agent(%{id: "registered-agent"})
      assert Registry.lookup("registered-agent") == {:ok, pid}
    end
  end

  describe "get_state/1" do
    test "returns current agent state" do
      pid = start_agent()
      state = Agent.get_state(pid)
      assert is_map(state)
      assert state.id != nil
      assert is_list(state.messages)
    end
  end

  describe "chat/2" do
    test "adds user message to state with index" do
      pid = start_agent()

      :ok = Agent.chat(pid, "Hello, agent!")

      state = Agent.get_state(pid)
      assert length(state.messages) == 1
      [message] = state.messages
      assert message.role == :user
      assert message.content == "Hello, agent!"
      assert message.index == 0
      assert is_map_key(message, :timestamp)
    end

    test "increments next_message_index after user message" do
      pid = start_agent()

      :ok = Agent.chat(pid, "First message")
      state = Agent.get_state(pid)
      assert state.next_message_index == 1
    end

    test "creates partial_message for assistant response" do
      pid = start_agent()

      :ok = Agent.chat(pid, "Hello")

      state = Agent.get_state(pid)
      assert state.partial_message != nil
      assert state.partial_message.index == 1
      assert state.partial_message.role == :assistant
      assert state.partial_message.content == ""
      assert state.partial_message.chars_sent == 0
      assert is_map_key(state.partial_message, :timestamp)
    end

    test "updates status to streaming" do
      pid = start_agent()

      :ok = Agent.chat(pid, "Hello")

      state = Agent.get_state(pid)
      assert state.status == :streaming
    end

    test "calls LLM and broadcasts response via PubSub" do
      # Use Mimic.stub_with to stub all LLMChain functions
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      pid = start_agent(%{model: %{name: "qwen3.5-plus"}})
      agent_id = Agent.get_state(pid).id

      # Subscribe to agent's PubSub topic
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Receive all deltas and final message via PubSub
      receive_deltas_and_message_from_pubsub()
    end

    test "accumulates delta content in partial_message" do
      # Use Mimic.stub_with to stub all LLMChain functions
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      pid = start_agent(%{model: %{name: "qwen3.5-plus"}})
      agent_id = Agent.get_state(pid).id

      # Subscribe to agent's PubSub topic
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Collect deltas and the final message via PubSub
      {partial_content, final_message} = collect_deltas_and_message_from_pubsub(pid)

      # Verify partial accumulated content matches final
      assert partial_content == final_message.content
      assert final_message.role == :assistant
    end

    test "clears partial_message and adds completed message on finish" do
      # Use Mimic.stub_with to stub all LLMChain functions
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      pid = start_agent(%{model: %{name: "qwen3.5-plus"}})
      agent_id = Agent.get_state(pid).id

      # Subscribe to agent's PubSub topic
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Wait for completion via PubSub
      receive do
        {:chat_message, %{index: index, role: :assistant, content: content}} ->
          state = Agent.get_state(pid)
          assert state.partial_message == nil
          assert state.status == :idle
          assert length(state.messages) == 2

          # Find the assistant message
          assistant_msg = Enum.find(state.messages, fn m -> m.index == index end)
          assert assistant_msg != nil
          assert assistant_msg.role == :assistant
          assert assistant_msg.content == content
          assert is_map_key(assistant_msg, :timestamp)
      after
        2000 ->
          flunk("Timeout waiting for assistant response")
      end
    end

    defp receive_deltas_and_message_from_pubsub do
      receive do
        {:chat_delta, _chunk} ->
          # Continue receiving deltas
          receive_deltas_and_message_from_pubsub()

        {:chat_message, %{role: :user}} ->
          # Skip user messages, continue waiting for assistant
          receive_deltas_and_message_from_pubsub()

        {:chat_message, %{role: :assistant, content: _}} = msg ->
          # Got the final message
          assert match?({:chat_message, %{role: :assistant, content: _}}, msg)
      after
        2000 ->
          flunk("Timeout waiting for assistant response")
      end
    end

    defp collect_deltas_and_message_from_pubsub(pid, acc \\ "") do
      receive do
        {:chat_delta, %{content: content}} ->
          # Verify partial is being accumulated
          state = Agent.get_state(pid)
          partial = state.partial_message

          if partial != nil do
            assert is_binary(partial.content)
          end

          # Continue collecting with accumulated content
          collect_deltas_and_message_from_pubsub(pid, acc <> content)

        {:chat_message, %{role: :user}} ->
          # Skip user messages, continue waiting for assistant
          collect_deltas_and_message_from_pubsub(pid, acc)

        {:chat_message, msg} ->
          # Return the accumulated content and the final message (assistant)
          {acc, msg}
      after
        2000 ->
          flunk("Timeout waiting for deltas")
      end
    end
  end

  describe "terminate/1" do
    test "stops agent process" do
      pid = start_agent(%{id: "terminating-agent"})
      assert Process.alive?(pid)

      Agent.terminate(pid)

      # Wait a bit for process to stop
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end
end
