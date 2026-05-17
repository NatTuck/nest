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
    test "joins agent channel and returns state with lastCompleteIndex", %{
      socket: socket,
      agent_id: id
    } do
      assert socket.topic == "agent:#{id}"
      assert_push "init", payload
      assert payload["id"] == id
      assert payload["model"][:name] == "qwen3.5-plus"
      assert payload["lastCompleteIndex"] == -1
      assert payload["status"] == "idle"
      # Init is lightweight - no messages or partial sent (client must sync)
      refute Map.has_key?(payload, "messages")
      refute Map.has_key?(payload, "partial")
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

  describe "init event with message history" do
    test "includes lastCompleteIndex after messages are added", %{socket: socket, agent_id: id} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message to create history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:message"} -> :ok
      after
        2000 -> flunk("Timeout waiting for message")
      end

      # Give the agent time to update its state
      Process.sleep(100)

      # Leave channel by stopping the channel process
      Process.unlink(socket.channel_pid)
      GenServer.stop(socket.channel_pid, :normal)

      # Wait for channel to close
      Process.sleep(50)

      # Drain any leftover messages in the mailbox
      Enum.each(1..10, fn _ ->
        receive do
          _ -> :ok
        after
          0 -> :ok
        end
      end)

      # Reconnect and rejoin channel
      {:ok, _, _new_socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      assert_push "init", payload, 2000
      assert payload["lastCompleteIndex"] >= 0
      assert payload["messages"] != []
    end
  end

  describe "handle_in(chat:message)" do
    test "sends message and returns ok", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}
    end

    test "broadcasts user message with index", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait and check if we receive appropriate broadcasts
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:delta", payload: payload} ->
          assert is_integer(payload["index"])
          assert is_binary(payload["content"])
          assert is_integer(payload["charsStart"])
          assert is_integer(payload["charsEnd"])
      after
        # No delta expected immediately
        500 -> :ok
      end
    end

    test "calls LLM and broadcasts response with deltas and index", %{socket: socket} do
      # Use Mimic.stub_with to stub all LLMChain functions
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Receive streaming deltas and final assistant message
      receive_deltas_and_message()
    end

    defp receive_deltas_and_message do
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:delta", payload: payload} ->
          # Verify delta format
          assert is_integer(payload["index"])
          assert is_binary(payload["content"])
          assert is_integer(payload["charsStart"])
          assert is_integer(payload["charsEnd"])
          assert payload["charsEnd"] > payload["charsStart"]

          # Continue receiving deltas
          receive_deltas_and_message()

        %Phoenix.Socket.Broadcast{event: "chat:message", payload: payload} ->
          assert is_integer(payload["index"])
          assert payload["index"] >= 0
          assert payload["role"] == :assistant
          assert is_binary(payload["content"])
      after
        2000 ->
          flunk("Timeout waiting for assistant response")
      end
    end
  end

  describe "handle_in(chat:sync)" do
    test "returns empty sync for new agent", %{socket: socket} do
      ref = push(socket, "chat:sync", %{"lastIndex" => -1})
      assert_reply ref, :ok, %{"messages" => [], "partial" => nil, "status" => "idle"}
    end

    test "returns messages after lastIndex", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send first message and wait for completion
      ref1 = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref1, :ok, %{}

      # Wait for assistant response to complete
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:message", payload: payload} ->
          first_index = payload["index"]
          # User is 0, assistant is 1
          assert first_index == 1
      after
        2000 -> flunk("Timeout waiting for first completion")
      end

      # Sync should return no new messages (we're up to date)
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => 1})
      assert_reply ref_sync, :ok, %{"messages" => [], "partial" => nil, "status" => "idle"}

      # Send second message
      ref2 = push(socket, "chat:message", %{"content" => "Second"})
      assert_reply ref2, :ok, %{}

      # Wait for second completion
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:message", payload: %{"index" => idx}} ->
          # Second user (2) + second assistant (3)
          assert idx == 3
      after
        2000 -> flunk("Timeout waiting for second completion")
      end

      # Sync from index 1 should return messages at index 2 and 3
      ref_sync2 = push(socket, "chat:sync", %{"lastIndex" => 1})

      assert_reply ref_sync2, :ok, %{
        "messages" => messages,
        "partial" => _partial,
        "status" => "idle"
      }

      assert length(messages) == 2
      assert Enum.all?(messages, fn m -> m["index"] > 1 end)
    end

    test "returns partial message when streaming", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Start streaming
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for at least one delta to ensure we're streaming
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:delta"} -> :ok
      after
        500 -> :ok
      end

      # Sync while streaming
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => 0})

      assert_reply ref_sync, :ok, %{
        "messages" => _messages,
        "partial" => partial,
        "status" => "streaming"
      }

      # Should have partial message
      if partial != nil do
        assert is_integer(partial["index"])
        assert is_binary(partial["content"])
        assert is_integer(partial["charsSent"])
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

  describe "handle_in(chat:status)" do
    test "returns status payload matching init format", %{socket: socket, agent_id: id} do
      ref = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref, :ok, %{
        "id" => status_id,
        "model" => model,
        "lastCompleteIndex" => last_index,
        "status" => status
      }

      assert status_id == id
      assert model[:name] == "qwen3.5-plus"
      assert last_index == -1
      assert status == "idle"
    end

    test "returns status with lastCompleteIndex after messages", %{socket: socket, agent_id: id} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message to create history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:message"} -> :ok
      after
        2000 -> flunk("Timeout waiting for message")
      end

      Process.sleep(100)

      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref_status, :ok, %{
        "id" => status_id,
        "lastCompleteIndex" => last_index,
        "status" => status
      }

      assert status_id == id
      assert last_index >= 0
      assert status == "idle"
    end

    test "returns streaming status during LLM response", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Start streaming
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for at least one delta
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:delta"} -> :ok
      after
        500 -> :ok
      end

      # Check status while streaming
      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref_status, :ok, %{
        "status" => status,
        "lastCompleteIndex" => _last_index
      }

      assert status == "streaming"
    end

    test "returns error when agent not found", %{socket: _socket} do
      # Create a new socket without joining to simulate non-existent agent
      assert {:error, %{"reason" => "agent not found"}} =
               subscribe_and_join(
                 socket(NestWeb.UserSocket),
                 NestWeb.AgentChannel,
                 "agent:nonexistent"
               )
    end
  end

  describe "chat:sync edge cases" do
    test "returns empty messages when lastIndex exceeds server's lastCompleteIndex", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message to create history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      receive do
        %Phoenix.Socket.Broadcast{event: "chat:message"} -> :ok
      after
        2000 -> flunk("Timeout")
      end

      Process.sleep(100)

      # Sync with lastIndex higher than server's lastCompleteIndex
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => 999})

      assert_reply ref_sync, :ok, %{
        "messages" => messages,
        "lastCompleteIndex" => last_complete_index
      }

      assert messages == []
      assert last_complete_index < 999
    end

    test "sync response includes lastCompleteIndex field", %{socket: socket} do
      ref = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref, :ok, reply

      assert reply["lastCompleteIndex"] == -1
    end

    test "sync with lastIndex: -1 returns all complete messages", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send first message
      ref1 = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref1, :ok, %{}

      receive do
        %Phoenix.Socket.Broadcast{event: "chat:message"} -> :ok
      after
        2000 -> flunk("Timeout waiting for first")
      end

      Process.sleep(100)

      # Sync with -1 should return all messages (user + assistant)
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref_sync, :ok, %{
        "messages" => messages,
        "lastCompleteIndex" => last_complete_index
      }

      # Should have both user (0) and assistant (1) messages
      assert length(messages) >= 2
      assert last_complete_index >= 1
    end
  end

  describe "chat:error event" do
    test "broadcasts error with index and content", %{socket: socket} do
      # Mock the LLM to fail
      Mimic.stub(LangChain.Chains.LLMChain, :run, fn _chain, _callback ->
        {:error, "model unavailable"}
      end)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      receive do
        %Phoenix.Socket.Broadcast{event: "chat:error", payload: payload} ->
          assert payload["index"] == 1
          assert is_binary(payload["content"])
          assert payload["content"] =~ "unavailable" or payload["content"] =~ "error"
      after
        2000 -> flunk("Timeout waiting for error")
      end
    end

    test "error event is broadcast when LLM fails" do
      # Stub the LLM to fail BEFORE creating the agent
      Mimic.stub(LangChain.Chains.LLMChain, :run, fn _chain, _callback ->
        {:error, "model failed"}
      end)

      # Create a separate agent for this test
      {:ok, error_agent_id} = Agents.create_agent(%{name: "qwen3.5-plus"})

      # Connect to the new agent
      {:ok, _, error_socket} =
        subscribe_and_join(
          socket(NestWeb.UserSocket),
          NestWeb.AgentChannel,
          "agent:#{error_agent_id}"
        )

      ref = push(error_socket, "chat:message", %{"content" => "Trigger error"})
      assert_reply ref, :ok, %{}

      # Wait for error broadcast
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:error", payload: error_payload} ->
          assert error_payload["index"] >= 0
          assert is_binary(error_payload["content"])
      after
        2000 -> flunk("Timeout waiting for error")
      end
    end
  end

  describe "message indexing rules" do
    test "assistant messages have odd indexes", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      messages_received = []

      # Send first message
      ref1 = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref1, :ok, %{}

      # Collect assistant messages (only type broadcast)
      messages_received =
        collect_messages(messages_received, 1, fn msg ->
          idx = msg["index"]
          role = msg["role"]

          # Assistant messages should have odd indexes
          if role == :assistant do
            assert rem(idx, 2) == 1
          end
        end)

      assert length(messages_received) >= 1
    end

    defp collect_messages(acc, count, validator, timeout \\ 5000) do
      if count <= 0 do
        acc
      else
        receive do
          %Phoenix.Socket.Broadcast{event: "chat:message", payload: payload} ->
            validator.(payload)
            collect_messages([payload | acc], count - 1, validator, timeout)
        after
          timeout -> acc
        end
      end
    end

    test "lastCompleteIndex is highest complete (non-partial) message", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for streaming to start
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:delta", payload: delta} ->
          partial_index = delta["index"]

          # Check status during streaming
          ref_status = push(socket, "chat:status", %{"lastIndex" => -1})
          assert_reply ref_status, :ok, %{"lastCompleteIndex" => last_complete}

          # Partial message index should be higher than lastCompleteIndex
          assert partial_index > last_complete
      after
        500 -> :ok
      end

      # Wait for completion
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:message", payload: msg} ->
          final_index = msg["index"]

          # After completion, lastCompleteIndex should match
          ref_status2 = push(socket, "chat:status", %{"lastIndex" => -1})
          assert_reply ref_status2, :ok, %{"lastCompleteIndex" => final_last}

          assert final_last == final_index
      after
        2000 -> flunk("Timeout waiting for completion")
      end
    end
  end

  describe "delta event details" do
    test "delta index matches message being streamed", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Capture first delta and verify all subsequent deltas have same index
      first_delta_index =
        receive do
          %Phoenix.Socket.Broadcast{event: "chat:delta", payload: payload} ->
            assert is_integer(payload["index"])
            payload["index"]
        after
          1000 -> flunk("Timeout waiting for delta")
        end

      # All subsequent deltas should have same index
      receive_deltas_with_index(first_delta_index, 3)
    end

    defp receive_deltas_with_index(expected_index, remaining) when remaining > 0 do
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:delta", payload: payload} ->
          assert payload["index"] == expected_index
          receive_deltas_with_index(expected_index, remaining - 1)
      after
        500 -> :ok
      end
    end

    defp receive_deltas_with_index(_expected_index, _remaining), do: :ok

    test "delta charsStart and charsEnd represent content slice", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      total_content = ""

      total_content =
        receive_deltas_and_build_content(total_content, fn delta ->
          start_pos = delta["charsStart"]
          end_pos = delta["charsEnd"]
          content = delta["content"]

          assert is_integer(start_pos)
          assert is_integer(end_pos)
          assert end_pos > start_pos
          assert String.length(content) == end_pos - start_pos
        end)

      assert String.length(total_content) > 0
    end

    defp receive_deltas_and_build_content(acc, validator, timeout \\ 2000) do
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:delta", payload: delta} ->
          validator.(delta)
          receive_deltas_and_build_content(acc <> delta["content"], validator, timeout)

        %Phoenix.Socket.Broadcast{event: "chat:message"} ->
          acc
      after
        timeout -> acc
      end
    end
  end

  describe "message broadcasting" do
    test "assistant message is broadcast to all subscribers", %{socket: socket, agent_id: id} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Connect a second client to the same channel
      {:ok, _, socket2} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      # First client sends message
      ref = push(socket, "chat:message", %{"content" => "Hello from client 1"})
      assert_reply ref, :ok, %{}

      # Second client should receive the assistant message broadcast (odd index)
      assistant_payload =
        receive do
          %Phoenix.Socket.Broadcast{event: "chat:message", payload: %{"index" => idx} = p}
          when rem(idx, 2) == 1 ->
            p
        after
          3000 -> flunk("Second client did not receive assistant message broadcast")
        end

      assert assistant_payload["role"] == :assistant
      assert is_binary(assistant_payload["content"])

      # Cleanup
      Process.unlink(socket2.channel_pid)
      GenServer.stop(socket2.channel_pid, :normal)
    end

    test "assistant message has correct index and role", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Test"})
      assert_reply ref, :ok, %{}

      # Assistant message is broadcast (odd index)
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:message", payload: payload} ->
          assert payload["role"] == :assistant
          assert is_binary(payload["content"])
          assert payload["index"] >= 1
          # Assistant messages should have odd indexes
          assert rem(payload["index"], 2) == 1
      after
        3000 -> flunk("Did not receive assistant message")
      end
    end
  end

  describe "status value constraints" do
    test "status is always idle or streaming", %{socket: socket} do
      # Initial status
      ref = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref, :ok, %{"status" => status}
      assert status in ["idle", "streaming"]
    end

    test "status transitions idle -> streaming -> idle", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Start idle
      ref1 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref1, :ok, %{"status" => "idle"}

      # Send message - should become streaming
      ref2 = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref2, :ok, %{}

      # Wait for streaming to start
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:delta"} -> :ok
      after
        500 -> :ok
      end

      ref3 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref3, :ok, %{"status" => "streaming"}

      # Wait for completion
      receive do
        %Phoenix.Socket.Broadcast{event: "chat:message"} -> :ok
      after
        2000 -> flunk("Timeout")
      end

      Process.sleep(100)

      # Should be idle again
      ref4 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref4, :ok, %{"status" => "idle"}
    end
  end
end
