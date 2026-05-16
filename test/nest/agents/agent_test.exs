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

  describe "set_channel/2" do
    test "sets channel pid for callbacks" do
      pid = start_agent()
      Agent.set_channel(pid, self())
      state = Agent.get_state(pid)
      assert state.channel_pid == self()
    end
  end

  describe "chat/2" do
    test "adds user message to state" do
      pid = start_agent()

      :ok = Agent.chat(pid, "Hello, agent!")

      state = Agent.get_state(pid)
      assert length(state.messages) == 1
      [message] = state.messages
      assert message.role == :user
      assert message.content == "Hello, agent!"
    end

    test "updates status to streaming" do
      pid = start_agent()
      Agent.set_channel(pid, self())

      :ok = Agent.chat(pid, "Hello")

      state = Agent.get_state(pid)
      assert state.status == :streaming
    end

    test "calls LLM and broadcasts response" do
      # Use Mimic.stub_with to stub all LLMChain functions
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      pid = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Agent.set_channel(pid, self())

      :ok = Agent.chat(pid, "Hello")

      # Receive all deltas and final message
      # The agent sends deltas first, then the final message
      receive_deltas_and_message()
    end

    defp receive_deltas_and_message do
      receive do
        {:delta, _chunk} ->
          # Continue receiving deltas
          receive_deltas_and_message()

        {:message, %{role: :assistant, content: _}} = msg ->
          # Got the final message
          assert match?({:message, %{role: :assistant, content: _}}, msg)
      after
        2000 ->
          flunk("Timeout waiting for assistant response")
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
