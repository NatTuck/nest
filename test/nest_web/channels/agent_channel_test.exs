defmodule NestWeb.AgentChannelTest do
  @moduledoc """
  Tests for the AgentChannel.
  """
  use NestWeb.ChannelCase

  import Mimic

  alias Nest.Agents

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    # Agents supervision tree is already started by Application
    # Create an agent with a model from test config
    {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})

    # Connect socket and join agent channel
    {:ok, _, socket} =
      subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

    {:ok, socket: socket, agent_id: id}
  end

  describe "join/3" do
    test "joins agent channel and returns state", %{socket: socket, agent_id: id} do
      assert socket.topic == "agent:#{id}"
      assert_push "init", payload
      assert payload["id"] == id
      assert payload["model"][:name] == "qwen3.5-plus"
    end

    test "returns error for non-existent agent" do
      assert {:error, %{"reason" => "agent not found"}} =
               subscribe_and_join(
                 socket(NestWeb.UserSocket),
                 NestWeb.AgentChannel,
                 "agent:nonexistent"
               )
    end
  end

  describe "handle_in(chat:message)" do
    test "sends message and returns ok", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}
    end

    test "calls LLM and broadcasts assistant response", %{socket: socket} do
      # Use Mimic.stub_with to stub all LLMChain functions
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Receive streaming deltas and final assistant message
      receive_deltas_and_message()
    end

    defp receive_deltas_and_message do
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:delta"} ->
          # Continue receiving deltas
          receive_deltas_and_message()

        %Phoenix.Socket.Broadcast{event: "chat:message", payload: %{"role" => :assistant}} = msg ->
          assert msg.payload["role"] == :assistant
          assert is_binary(msg.payload["content"])
      after
        2000 ->
          flunk("Timeout waiting for assistant response")
      end
    end
  end

  describe "terminate/2" do
    test "cleans up channel subscription", %{socket: socket, agent_id: id} do
      # Simulate disconnect by leaving the channel
      Process.unlink(socket.channel_pid)
      GenServer.stop(socket.channel_pid, :normal)

      Process.sleep(50)

      # Agent should still exist (no auto-terminate)
      assert {:ok, _} = Agents.get_agent(id)
    end
  end
end
