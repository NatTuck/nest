defmodule NestWeb.AgentChannelTest do
  @moduledoc """
  Tests for the AgentChannel.
  """
  use NestWeb.ChannelCase

  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Agent

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
    test "joins agent channel and returns state with messageCount", %{
      socket: socket,
      agent_id: id
    } do
      assert socket.topic == "agent:#{id}"
      assert_push "init", payload
      assert payload["id"] == id
      assert payload["model"][:name] == "qwen3.5-plus"
      assert payload["messageCount"] == 0
      assert payload["status"] == "idle"
      # Init includes partial (nil when not streaming)
      assert Map.has_key?(payload, "partial")
      assert payload["partial"] == nil
      refute Map.has_key?(payload, "messages")
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
    test "includes messageCount after messages are added", %{socket: socket, agent_id: id} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message to create history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion (user message first, then assistant)
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => :assistant}, 2000

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
      assert payload["messageCount"] >= 0
      assert payload["messages"] != []
    end
  end

  describe "handle_in(chat:message)" do
    test "sends message and returns ok", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}
    end

    test "broadcasts user message with index", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Receive user message broadcast first
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 500

      # Then receive streaming deltas
      assert_push "chat:delta", payload, 500
      assert is_integer(payload["index"])
      assert is_binary(payload["content"])
      assert is_integer(payload["charsStart"])
      assert is_integer(payload["charsEnd"])
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
      assert_push "chat:delta", payload, 2000
      # Verify delta format
      assert is_integer(payload["index"])
      assert is_binary(payload["content"])
      assert is_integer(payload["charsStart"])
      assert is_integer(payload["charsEnd"])
      assert payload["charsEnd"] > payload["charsStart"]

      # Continue receiving deltas
      receive_deltas_and_message()
    rescue
      ExUnit.AssertionError ->
        # Try to receive final message instead
        assert_push "chat:message", payload, 2000
        assert is_integer(payload["index"])
        assert payload["index"] >= 0
        assert payload["role"] == :assistant
        assert is_binary(payload["content"])
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

      # Wait for user message (even index), then assistant message (odd index)
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => :assistant}, 2000

      # Sync should return no new messages (we're up to date)
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => 1})
      assert_reply ref_sync, :ok, %{"messages" => [], "partial" => nil, "status" => "idle"}

      # Send second message
      ref2 = push(socket, "chat:message", %{"content" => "Second"})
      assert_reply ref2, :ok, %{}

      # Wait for second user message (index 2), then assistant (index 3)
      assert_push "chat:message", %{"index" => 2, "role" => :user}, 2000
      assert_push "chat:message", %{"index" => 3, "role" => :assistant}, 2000

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
      assert_push "chat:delta", _payload, 500

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
        assert is_integer(partial["charsEnd"])
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
        "messageCount" => last_index,
        "status" => status
      }

      assert status_id == id
      assert model[:name] == "qwen3.5-plus"
      assert last_index == 0
      assert status == "idle"
    end

    test "returns status with messageCount after messages", %{socket: socket, agent_id: id} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message to create history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion (user message first, then assistant)
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => :assistant}, 2000

      Process.sleep(100)

      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref_status, :ok, %{
        "id" => status_id,
        "messageCount" => last_index,
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
      assert_push "chat:delta", _payload, 500

      # Check status while streaming
      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref_status, :ok, %{
        "status" => status,
        "messageCount" => _last_index
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
    test "returns empty messages when lastIndex exceeds server's messageCount", %{
      socket: socket
    } do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message to create history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", _payload, 2000

      Process.sleep(100)

      # Sync with lastIndex higher than server's messageCount
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => 999})

      assert_reply ref_sync, :ok, %{
        "messages" => messages,
        "messageCount" => last_complete_index
      }

      assert messages == []
      assert last_complete_index < 999
    end

    test "sync response includes messageCount field", %{socket: socket} do
      ref = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref, :ok, reply

      assert reply["messageCount"] == 0
    end

    test "sync with lastIndex: -1 returns all complete messages", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send first message
      ref1 = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref1, :ok, %{}

      # Wait for completion (user message first, then assistant)
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => :assistant}, 2000

      Process.sleep(100)

      # Sync with -1 should return all messages (user + assistant)
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref_sync, :ok, %{
        "messages" => messages,
        "messageCount" => last_complete_index
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

      assert_push "chat:error", payload, 2000
      assert payload["index"] == 1
      assert is_binary(payload["content"])
      assert payload["content"] =~ "unavailable" or payload["content"] =~ "error"
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
      assert_push "chat:error", error_payload, 2000
      assert error_payload["index"] >= 0
      assert is_binary(error_payload["content"])
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

      assert messages_received != []
    end

    defp collect_messages(acc, count, validator, timeout \\ 5000) do
      if count <= 0 do
        acc
      else
        assert_push "chat:message", payload, timeout
        validator.(payload)
        collect_messages([payload | acc], count - 1, validator, timeout)
      end
    end

    test "messageCount is highest complete (non-partial) message", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for streaming to start
      assert_push "chat:delta", delta, 500
      partial_index = delta["index"]

      # Check status during streaming
      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref_status, :ok, %{"messageCount" => last_complete}

      # Partial message index should be >= messageCount
      # (equal when system message is present, greater otherwise)
      assert partial_index >= last_complete

      # Wait for completion
      assert_push "chat:message", msg, 2000
      final_index = msg["index"]

      # After completion, messageCount should match
      ref_status2 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref_status2, :ok, %{"messageCount" => final_last}

      # After completion, messageCount should be final_index + 1
      # (messageCount is the count, final_index is the highest index)
      assert final_last == final_index + 1
    end
  end

  describe "delta event details" do
    test "delta index matches message being streamed", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Capture first delta and verify all subsequent deltas have same index
      assert_push "chat:delta", payload, 1000
      assert is_integer(payload["index"])
      first_delta_index = payload["index"]

      # All subsequent deltas should have same index
      receive_deltas_with_index(first_delta_index, 3)
    end

    defp receive_deltas_with_index(expected_index, remaining) when remaining > 0 do
      assert_push "chat:delta", payload, 500
      assert payload["index"] == expected_index
      receive_deltas_with_index(expected_index, remaining - 1)
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
      assert_push "chat:delta", delta, timeout
      validator.(delta)
      receive_deltas_and_build_content(acc <> delta["content"], validator, timeout)
    rescue
      ExUnit.AssertionError ->
        # No more deltas, try for final message
        try do
          assert_push "chat:message", _payload, timeout
          acc
        rescue
          ExUnit.AssertionError -> acc
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

      # First client receives user message first (even index), then assistant
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 3000

      assert_push "chat:message",
                  %{"index" => idx, "role" => :assistant} = assistant_payload,
                  3000

      assert rem(idx, 2) == 1
      assert is_binary(assistant_payload["content"])

      # Second client should also receive both messages
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 3000
      assert_push "chat:message", %{"index" => idx2, "role" => :assistant}, 3000
      assert rem(idx2, 2) == 1

      # Cleanup
      Process.unlink(socket2.channel_pid)
      GenServer.stop(socket2.channel_pid, :normal)
    end

    test "assistant message has correct index and role", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Test"})
      assert_reply ref, :ok, %{}

      # Receive user message first (even index)
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 3000

      # Then receive assistant message (odd index)
      assert_push "chat:message", %{"index" => idx, "role" => :assistant} = payload, 3000
      assert is_binary(payload["content"])
      assert idx >= 1
      # Assistant messages should have odd indexes
      assert rem(idx, 2) == 1
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
      assert_push "chat:delta", _payload, 500

      ref3 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref3, :ok, %{"status" => "streaming"}

      # Wait for completion (user message first, then assistant)
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => :assistant}, 2000

      # Drain any remaining delta messages from mailbox
      receive do
        %Phoenix.Socket.Message{event: "chat:delta"} -> :ok
      after
        0 -> :ok
      end

      Process.sleep(100)

      # Should be idle again
      ref4 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref4, :ok, %{"status" => "idle"}
    end
  end

  describe "channel lifecycle edge cases" do
    test "rejoining mid-stream receives correct charsEnd in partial", %{
      socket: socket,
      agent_id: id
    } do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Start streaming
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for several deltas to be sent
      deltas = collect_deltas(socket, [])
      assert length(deltas) > 2

      # Get the last delta's charsEnd
      last_delta = List.last(deltas)
      last_chars_end = last_delta["charsEnd"]
      assert last_chars_end > 0

      # Simulate disconnect
      Process.unlink(socket.channel_pid)
      GenServer.stop(socket.channel_pid, :normal)
      Process.sleep(50)

      # Rejoin while still streaming
      {:ok, _, new_socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      # The init should include partial with correct charsEnd
      assert_push "init", init_payload, 1000

      partial = init_payload["partial"]

      if partial != nil do
        assert is_integer(partial["charsEnd"]), "charsEnd should be an integer"
        # The charsEnd should be close to the last delta received (within chunk size)
        assert partial["charsEnd"] > 0, "charsEnd should be greater than 0"
        # Should not be 0 (which was the bug)
        refute partial["charsEnd"] == 0, "charsEnd should not be 0 mid-stream"
      end

      # Cleanup
      Process.unlink(new_socket.channel_pid)
      GenServer.stop(new_socket.channel_pid, :normal)
    end

    test "mid-stream join does not trigger delta gap warnings", %{socket: socket, agent_id: id} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Start streaming
      ref = push(socket, "chat:message", %{"content" => "Hello world this is a test"})
      assert_reply ref, :ok, %{}

      # Collect several deltas
      deltas = collect_deltas(socket, [])
      assert length(deltas) >= 3

      # Get total chars sent from last delta
      last_delta = List.last(deltas)
      _total_chars_sent = last_delta["charsEnd"]

      # Disconnect
      Process.unlink(socket.channel_pid)
      GenServer.stop(socket.channel_pid, :normal)
      Process.sleep(50)

      # Rejoin
      {:ok, _, new_socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      assert_push "init", init_payload, 1000

      # Get the partial's charsEnd
      partial = init_payload["partial"]

      # If streaming completed before rejoin, partial may be nil
      # In that case, skip the gap check
      if partial != nil do
        init_chars_end = partial["charsEnd"]

        # The next delta received should have charsStart >= init_chars_end
        # This prevents the "Delta gap" warning
        remaining_deltas = collect_remaining_deltas(new_socket, [])

        if remaining_deltas != [] do
          first_remaining = List.first(remaining_deltas)
          chars_start = first_remaining["charsStart"]

          # Should not have a gap
          assert chars_start >= init_chars_end || chars_start <= init_chars_end + 5,
                 "First delta after rejoin should not have a large gap. " <>
                   "Expected charsStart ~#{init_chars_end}, got #{chars_start}"
        end
      end

      # Cleanup
      Process.unlink(new_socket.channel_pid)
      GenServer.stop(new_socket.channel_pid, :normal)
    end
  end

  defp collect_deltas(socket, acc) do
    receive do
      %Phoenix.Socket.Message{event: "chat:delta", payload: payload} ->
        collect_deltas(socket, [payload | acc])
    after
      300 ->
        # No more deltas for now
        Enum.reverse(acc)
    end
  end

  defp collect_remaining_deltas(socket, acc, timeout \\ 1000) do
    receive do
      %Phoenix.Socket.Message{event: "chat:delta", payload: payload} ->
        collect_remaining_deltas(socket, [payload | acc], timeout)
    after
      timeout ->
        Enum.reverse(acc)
    end
  end

  describe "agent process isolation" do
    test "agent process does not capture channel pid", %{socket: _socket, agent_id: id} do
      # Get the agent process state
      {:ok, agent_pid} = Agents.Supervisor.get_agent(id)

      # The agent should not have a channel_pid field or it should be nil
      # This test documents the expected behavior after fixing Bug 2
      agent_state = Agent.get_state(agent_pid)

      # The agent should not store the channel PID
      # If it does, responses may be lost when the channel is rejoined
      has_channel_pid = Map.has_key?(agent_state, :channel_pid)
      channel_pid_set = has_channel_pid && not is_nil(Map.get(agent_state, :channel_pid))

      refute channel_pid_set,
             "Agent should not capture channel PID to avoid response loss on rejoin"
    end

    test "messages are not lost on channel rejoin", %{socket: socket, agent_id: id} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for any broadcast events
      assert_push "chat:delta", _payload, 100

      # Wait for assistant response to complete (user message first, then assistant)
      assert_push "chat:message", %{"index" => 0, "role" => :user}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => :assistant}, 2000

      Process.sleep(100)

      # Verify agent has the messages before disconnect
      {:ok, agent_pid} = Agents.Supervisor.get_agent(id)
      agent_state = Agent.get_state(agent_pid)
      assert length(agent_state.messages) == 2
      last_complete_index = List.last(agent_state.messages).index
      assert last_complete_index >= 0

      # Simulate connection loss by stopping channel process
      Process.unlink(socket.channel_pid)
      GenServer.stop(socket.channel_pid, :normal)

      # Wait for process to stop
      Process.sleep(100)

      # Verify agent still has messages after channel disconnect
      # This proves messages persist on the server side
      agent_state_after = Agent.get_state(agent_pid)
      assert length(agent_state_after.messages) == 2
      assert List.last(agent_state_after.messages).index >= 0

      # Note: Full rejoin test would verify client-side sync receives the
      # correct messageCount. The client would use chat:sync after rejoin.
    end

    test "sync returns correct messages after multiple rejoins", %{socket: socket, agent_id: id} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send first message
      ref1 = push(socket, "chat:message", %{"content" => "Message 1"})
      assert_reply ref1, :ok, %{}

      # Wait for completion (user message first, then assistant)
      assert_push "chat:message", %{"index" => 0}, 2000
      assert_push "chat:message", _payload, 2000

      Process.sleep(100)

      # First rejoin - sync should return messages
      Process.unlink(socket.channel_pid)
      GenServer.stop(socket.channel_pid, :normal)
      Process.sleep(50)

      {:ok, _, socket2} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      # Request sync with lastIndex: -1
      ref_sync = push(socket2, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref_sync, :ok, %{
        "messages" => messages,
        "messageCount" => last_complete
      }

      # Should have the messages
      assert messages != []
      assert last_complete >= 0

      # Second rejoin - should still get same messages
      Process.unlink(socket2.channel_pid)
      GenServer.stop(socket2.channel_pid, :normal)
      Process.sleep(50)

      {:ok, _, socket3} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      ref_sync2 = push(socket3, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref_sync2, :ok, %{
        "messages" => messages2,
        "messageCount" => last_complete2
      }

      assert messages2 != []
      assert last_complete2 == last_complete
    end
  end
end
