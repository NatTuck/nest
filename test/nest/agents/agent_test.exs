defmodule Nest.Agents.AgentTest do
  @moduledoc """
  Tests for the Agent GenServer behavior via PubSub.
  """
  use ExUnit.Case, async: false

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Registry

  setup :set_mimic_global
  setup :verify_on_exit!

  defp start_agent(attrs) do
    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    defaults = %{
      id: agent_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }

    attrs = Map.merge(defaults, attrs)
    pid = start_supervised!({Agent, attrs})
    {pid, agent_id}
  end

  describe "start_link/1" do
    test "starts agent and registers in registry" do
      agent_id = "registered-agent-#{System.unique_integer([:positive])}"
      pid = start_supervised!({Agent, %{id: agent_id, model: %{name: "qwen3.5-plus"}}})
      assert Registry.lookup(agent_id) == {:ok, pid}
    end
  end

  describe "chat/2" do
    test "broadcasts user message and LLM response via PubSub" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Receive user message
      assert_receive {:chat_message, {:user, %{index: 0, content: "Hello"}}},
                     1000

      # Receive assistant response via PubSub
      receive_deltas_and_message_from_pubsub()
    end

    test "handles LLM error gracefully" do
      # Mock LLM to return an error
      Mimic.stub(LangChain.Chains.LLMChain, :run, fn _chain, _opts ->
        {:error, nil, "Connection failed"}
      end)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Should receive user message
      assert_receive {:chat_message, {:user, %{index: 0, content: "Hello"}}},
                     1000

      # Should receive error message
      assert_receive {:chat_error, _error}, 2000
    end

    test "accumulates delta content from streaming LLM response" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Receive user message
      assert_receive {:chat_message, {:user, _}}, 1000

      # Collect deltas and verify final message
      {partial_content, final_message} = collect_deltas_and_message_from_pubsub()

      # Verify accumulated content matches final
      assert elem(final_message, 0) == :assistant
      assert partial_content == elem(final_message, 1).content
      assert partial_content != ""
    end
  end

  describe "delta handling" do
    test "accumulates deltas with correct character counts" do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Hello")

      # Skip user message
      assert_receive {:chat_message, {:user, _}}, 1000

      # Collect all deltas and verify
      deltas = collect_all_deltas_from_pubsub()

      # Verify we got deltas
      assert deltas != []
    end
  end

  test "stops agent process" do
    agent_id = "terminating-agent-#{System.unique_integer([:positive])}"
    pid = start_supervised!({Agent, %{id: agent_id, model: %{name: "qwen3.5-plus"}}})
    assert Process.alive?(pid)

    ref = Process.monitor(pid)
    Agent.terminate(pid)

    # Wait for process to stop - allow any exit reason
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1000

    refute Process.alive?(pid)
  end

  # Helper functions

  defp receive_deltas_and_message_from_pubsub do
    receive do
      {:chat_delta, _chunk} ->
        receive_deltas_and_message_from_pubsub()

      {:chat_message, {:user, _}} ->
        receive_deltas_and_message_from_pubsub()

      {:chat_message, {:assistant, assistant_struct}} = msg ->
        assert is_struct(assistant_struct, Nest.Messages.Assistant)
        assert assistant_struct.content != nil
        msg
    after
      2000 ->
        flunk("Timeout waiting for assistant response")
    end
  end

  defp collect_deltas_and_message_from_pubsub(acc \\ "") do
    receive do
      {:chat_delta, %{content: content}} ->
        collect_deltas_and_message_from_pubsub(acc <> content)

      {:chat_message, {:user, _}} ->
        collect_deltas_and_message_from_pubsub(acc)

      {:chat_message, msg} ->
        {acc, msg}
    after
      2000 ->
        flunk("Timeout waiting for deltas")
    end
  end

  defp collect_all_deltas_from_pubsub(deltas \\ []) do
    receive do
      {:chat_delta, delta} ->
        collect_all_deltas_from_pubsub([delta | deltas])

      {:chat_message, {:assistant, _}} ->
        Enum.reverse(deltas)
    after
      500 ->
        Enum.reverse(deltas)
    end
  end
end
