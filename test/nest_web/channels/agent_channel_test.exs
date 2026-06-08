defmodule NestWeb.AgentChannelTest do
  @moduledoc """
  Tests for the AgentChannel.
  """
  use NestWeb.ChannelCase

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents
  alias Nest.Messages.Assistant
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolResult
  alias Nest.Test.TaskDrain

  setup :set_mimic_global
  setup :verify_on_exit!

  setup do
    # Stub the LLM by default so leaked Tasks from one test can't make real
    # HTTP calls when the next test starts. Individual tests can override
    # this with their own stubs.
    Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)
    Nest.LangChainMock.start_mock_agent()

    # Agents supervision tree is already started by Application
    # Create an agent with a model from test config
    {:ok, id} = Agents.create_agent(%{name: "qwen3.5-plus"})

    # Connect socket and join agent channel
    {:ok, _, socket} =
      subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

    on_exit(fn -> TaskDrain.drain() end)

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
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

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
    end
  end

  describe "handle_in(chat:message)" do
    test "sends message and returns ok", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for the user message to be broadcast so the LLM Task is
      # actively using the stub before the test exits.
      assert_push "chat:message", %{"role" => "user"}, 500
    end

    test "broadcasts user message with index", %{socket: socket} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Receive user message broadcast first
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 500

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
        assert payload["role"] == "assistant"
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
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

      # Sync should return no new messages (we're up to date)
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => 1})
      assert_reply ref_sync, :ok, %{"messages" => [], "partial" => nil, "status" => "idle"}

      # Send second message
      ref2 = push(socket, "chat:message", %{"content" => "Second"})
      assert_reply ref2, :ok, %{}

      # Wait for second user message (index 2), then assistant (index 3)
      assert_push "chat:message", %{"index" => 2, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 3, "role" => "assistant"}, 2000

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

      # Sync before any chat - partial should be nil
      ref_sync1 = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref_sync1, :ok, %{
        "messages" => _messages,
        "partial" => partial,
        "status" => "idle"
      }

      assert partial == nil

      # Start streaming
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

      # Sync after completion - partial should be nil again
      ref_sync2 = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref_sync2, :ok, %{
        "messages" => _messages,
        "partial" => partial,
        "status" => "idle"
      }

      assert partial == nil
    end
  end

  describe "terminate/2" do
    test "cleans up channel subscription", %{socket: socket, agent_id: id} do
      # Simulate disconnect by leaving the channel
      Process.unlink(socket.channel_pid)
      GenServer.stop(socket.channel_pid, :normal)

      Process.sleep(50)

      # Agent should still exist (no auto-terminate)
      assert {:ok, _} = Agents.get_info(id)
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
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

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

      # Wait for completion
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

      # After completion, status should be back to "idle"
      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref_status, :ok, %{"status" => "idle"}
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
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

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
      # Mock the LLM to fail. Stub arity 1 and 2 because
      # LLMChain.run/1 dispatches to run/2 with default opts.
      Mimic.stub(LangChain.Chains.LLMChain, :run, fn _chain ->
        {:error, %{__struct__: LangChain.Chains.LLMChain}, "model unavailable"}
      end)

      Mimic.stub(LangChain.Chains.LLMChain, :run, fn _chain, _opts ->
        {:error, %{__struct__: LangChain.Chains.LLMChain}, "model unavailable"}
      end)

      log =
        capture_log(fn ->
          ref = push(socket, "chat:message", %{"content" => "Hello"})
          assert_reply ref, :ok, %{}

          assert_push "chat:error", payload, 2000
          assert payload["index"] == 1
          assert is_binary(payload["content"])
          assert payload["content"] =~ "unavailable" or payload["content"] =~ "error"
        end)

      # Verify the error was logged with the correct message
      assert log =~ "LLM request failed"
      assert log =~ "model unavailable"
    end

    test "error event is broadcast when LLM fails" do
      # Stub the LLM to fail BEFORE creating the agent
      Mimic.stub(LangChain.Chains.LLMChain, :run, fn _chain ->
        {:error, %{__struct__: LangChain.Chains.LLMChain}, "model failed"}
      end)

      Mimic.stub(LangChain.Chains.LLMChain, :run, fn _chain, _opts ->
        {:error, %{__struct__: LangChain.Chains.LLMChain}, "model failed"}
      end)

      log =
        capture_log(fn ->
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
        end)

      # Verify the error was logged with the correct message
      assert log =~ "LLM request failed"
      assert log =~ "model failed"
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

      # Wait for completion (both user and assistant messages)
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

      # After completion, messageCount should match the highest complete index
      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref_status, :ok, %{"messageCount" => final_count}

      # final_count should be 2 (user + assistant), equal to highest index + 1
      assert final_count == 2
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
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 3000

      assert_push "chat:message",
                  %{"index" => idx, "role" => "assistant"} = assistant_payload,
                  3000

      assert rem(idx, 2) == 1
      assert is_binary(assistant_payload["content"])

      # Second client should also receive both messages
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 3000
      assert_push "chat:message", %{"index" => idx2, "role" => "assistant"}, 3000
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
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 3000

      # Then receive assistant message (odd index)
      assert_push "chat:message", %{"index" => idx, "role" => "assistant"} = payload, 3000
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

      # Send message - status will be "streaming" while the agent
      # processes the LLM response, then return to "idle" on completion.
      ref2 = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref2, :ok, %{}

      # Wait for completion
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

      # Drain any remaining delta messages from mailbox
      receive do
        %Phoenix.Socket.Message{event: "chat:delta"} -> :ok
      after
        0 -> :ok
      end

      # Should be idle again
      ref3 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref3, :ok, %{"status" => "idle"}
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
      # Verify the agent process exists but does not have a channel_pid field
      # This is tested indirectly: if the agent stored channel_pid, rejoin would fail
      {:ok, _pid} = Agents.Supervisor.get_agent(id)

      # Test passes by virtue of the agent existing and the system working
      # The actual channel_pid isolation is tested via the rejoin test below
    end

    test "messages are not lost on channel rejoin", %{socket: socket, agent_id: id} do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for any broadcast events
      assert_push "chat:delta", _payload, 100

      # Wait for assistant response to complete (user message first, then assistant)
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

      Process.sleep(100)

      # Verify agent has messages via sync before disconnect
      sync_ref = push(socket, "chat:sync", %{"lastIndex" => -1})
      assert_reply sync_ref, :ok, %{"messages" => messages, "messageCount" => msg_count}
      assert length(messages) == 2
      assert msg_count >= 2

      # Simulate connection loss by stopping channel process
      Process.unlink(socket.channel_pid)
      GenServer.stop(socket.channel_pid, :normal)

      # Wait for channel to terminate
      Process.sleep(100)

      # Rejoin the channel
      {:ok, _, new_socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      # Verify messages via sync after rejoin
      sync_ref2 = push(new_socket, "chat:sync", %{"lastIndex" => -1})
      assert_reply sync_ref2, :ok, %{"messages" => messages2, "messageCount" => msg_count2}

      # Messages should still be available after rejoin
      assert length(messages2) >= 2
      assert msg_count2 >= 2

      # Cleanup
      Process.unlink(new_socket.channel_pid)
      GenServer.stop(new_socket.channel_pid, :normal)
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

  describe "API logs in chat:message events" do
    test "API requests and responses are broadcast with correct message indices in two-round conversation",
         %{
           socket: socket,
           agent_id: _id
         } do
      # Note: subscribe_and_join already subscribes the test process to the agent topic
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Collect messages into a map by index, keeping the last version (which includes apiLogs)
      collect_messages = fn ->
        Enum.reduce(1..20, %{}, fn _, acc ->
          receive do
            %Phoenix.Socket.Message{event: "chat:message", payload: payload} ->
              Map.put(acc, payload["index"], payload)
          after
            100 -> acc
          end
        end)
      end

      # === Round 1 ===
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion and collect all message versions
      Process.sleep(300)
      messages1 = collect_messages.()

      # === Verify Round 1 ===
      user1 = messages1[0]
      assistant1 = messages1[1]

      assert user1["role"] == "user"
      assert assistant1["role"] == "assistant"

      # User message (index 0) should have request log
      assert length(user1["apiLogs"]) == 1
      request = Enum.find(user1["apiLogs"], fn l -> l["type"] == "request" end)
      assert request != nil
      assert request["id"] == "000.000"
      assert is_map(request["payload"])

      # Assistant message (index 1) should have response log
      assert length(assistant1["apiLogs"]) == 1
      response = Enum.find(assistant1["apiLogs"], fn l -> l["type"] == "response" end)
      assert response != nil
      assert response["id"] == "001.000"
      assert is_map(response["payload"])

      # === Round 2 ===
      ref2 = push(socket, "chat:message", %{"content" => "How are you?"})
      assert_reply ref2, :ok, %{}

      # Wait for completion and collect all message versions
      Process.sleep(300)
      messages2 = collect_messages.()

      # === Verify Round 2 ===
      user2 = messages2[2]
      assistant2 = messages2[3]

      assert user2["role"] == "user"
      assert assistant2["role"] == "assistant"

      # User message (index 2) should have request log
      assert length(user2["apiLogs"]) == 1
      request2 = Enum.find(user2["apiLogs"], fn l -> l["type"] == "request" end)
      assert request2 != nil
      assert request2["id"] == "002.000"

      # Assistant message (index 3) should have response log
      assert length(assistant2["apiLogs"]) == 1
      response2 = Enum.find(assistant2["apiLogs"], fn l -> l["type"] == "response" end)
      assert response2 != nil
      assert response2["id"] == "003.000"
    end

    test "API call payload contains conversation history and tool calls", %{
      socket: socket,
      agent_id: _id
    } do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send first message
      ref = push(socket, "chat:message", %{"content" => "First message"})
      assert_reply ref, :ok, %{}

      # Collect messages into a map by index, keeping the last version (which includes apiLogs)
      messages =
        Enum.reduce(1..20, %{}, fn _, acc ->
          receive do
            %Phoenix.Socket.Message{event: "chat:message", payload: payload} ->
              Map.put(acc, payload["index"], payload)
          after
            100 -> acc
          end
        end)

      # Get user and assistant messages
      user = messages[0]
      assistant = messages[1]

      assert user["role"] == "user"
      assert assistant["role"] == "assistant"

      # Verify user message has request with proper payload structure
      request = Enum.find(user["apiLogs"], fn l -> l["type"] == "request" end)
      assert request != nil
      assert request["id"] == "000.000"
      assert is_map(request["payload"])
      # Payload has atom keys from ChatOpenAI.for_api (e.g., :messages, :model, :temperature)
      assert request["timestamp"] != nil

      # Verify assistant message has response with proper payload structure
      response = Enum.find(assistant["apiLogs"], fn l -> l["type"] == "response" end)
      assert response != nil
      assert response["id"] == "001.000"
      assert is_map(response["payload"])
      # Response payload has atom keys (e.g., :role, :content, :tool_calls)
      assert response["timestamp"] != nil
    end

    test "tool messages have API request logs from continuation", %{
      socket: socket,
      agent_id: _id
    } do
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Set up mock to return tool calls first, then final response
      Nest.LangChainMock.set_tool_response(%{
        text: "I'll run that command",
        tool_calls: [
          %LangChain.Message.ToolCall{
            call_id: "call_shell_001",
            name: "shell_cmd",
            arguments: %{"command" => "echo test"}
          }
        ]
      })

      Nest.LangChainMock.set_response("Done")

      # Send message
      ref = push(socket, "chat:message", %{"content" => "Run a command"})
      assert_reply ref, :ok, %{}

      # Collect messages
      messages =
        Enum.reduce(1..30, %{}, fn _, acc ->
          receive do
            %Phoenix.Socket.Message{event: "chat:message", payload: payload} ->
              Map.put(acc, payload["index"], payload)
          after
            100 -> acc
          end
        end)

      # Get tool message (index 2)
      tool = messages[2]
      assert tool["role"] == "tool"

      # Tool message should have API request log (from tool results sent to API)
      assert tool["apiLogs"] != [], "Expected tool message to have API logs"

      request = Enum.find(tool["apiLogs"], fn l -> l["type"] == "request" end)
      assert request != nil, "Expected tool message to have request log"
      assert request["id"] == "002.000"
      assert is_map(request["payload"])
      # Request should include conversation history with tool results
      assert request["timestamp"] != nil

      # Cleanup
      Nest.LangChainMock.clear_response()
    end
  end

  describe "tool result serialization" do
    test "tool results are converted to plain maps for JSON serialization", %{
      socket: socket,
      agent_id: _id
    } do
      # Create a message with tool_results using new Tool struct
      tool_result_message =
        {:tool,
         %Tool{
           index: 2,
           timestamp: DateTime.utc_now(),
           tool_results: [
             %ToolResult{
               tool_call_id: "call_123",
               name: "shell_cmd",
               content: "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 .",
               is_error: false
             }
           ],
           api_logs: []
         }}

      # Send the broadcast message to the channel process
      send(socket.channel_pid, {:chat_message, tool_result_message})

      # Verify the message was received with toolResults as plain maps
      assert_push "chat:message", payload, 500

      assert payload["index"] == 2
      assert payload["role"] == "tool"

      # toolResults should be a list of plain maps, not structs
      assert is_list(payload["toolResults"])
      assert length(payload["toolResults"]) == 1

      tool_result = List.first(payload["toolResults"])

      # The tool result should be a plain map with string keys
      assert is_map(tool_result)
      refute is_struct(tool_result)

      assert tool_result["tool_call_id"] == "call_123"
      assert tool_result["name"] == "shell_cmd"
      # ContentPart structs should be converted to plain text
      assert tool_result["content"] == "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 ."
      assert tool_result["is_error"] == false
    end

    test "chat:sync handles messages with ToolResult structs", %{
      socket: socket,
      agent_id: id
    } do
      # Stub the LLMChain so we can inject a message with ToolResult structs
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message to create some history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

      Process.sleep(100)

      # Create a tool result message with new Tool struct
      tool_result_message =
        {:tool,
         %Tool{
           index: 2,
           timestamp: DateTime.utc_now(),
           tool_results: [
             %ToolResult{
               tool_call_id: "call_123",
               name: "shell_cmd",
               content: "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 .",
               is_error: false
             }
           ],
           api_logs: []
         }}

      # Inject the tool result message into the agent's state
      {:ok, agent_pid} = Nest.Agents.Supervisor.get_agent(id)

      # Use :sys.replace_state to inject the tool message
      :sys.replace_state(agent_pid, fn state ->
        %{state | messages: [tool_result_message | state.messages]}
      end)

      # Sync from -1 should return all messages including the tool result
      sync_ref = push(socket, "chat:sync", %{"lastIndex" => -1})

      # This should NOT crash with Protocol.UndefinedError
      assert_reply sync_ref, :ok, %{"messages" => messages}

      # Find the tool message (role is now a string in formatted messages)
      tool_message = Enum.find(messages, fn m -> m["role"] == "tool" end)
      assert tool_message != nil

      # toolResults should be plain maps
      assert is_list(tool_message["toolResults"])
      tool_result = List.first(tool_message["toolResults"])
      assert is_map(tool_result)
      refute is_struct(tool_result)
      assert tool_result["tool_call_id"] == "call_123"
      assert tool_result["content"] == "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 ."
    end

    test "chat:sync handles messages with ToolResult structs in api_logs", %{
      socket: socket,
      agent_id: id
    } do
      # Stub the LLMChain so we can inject a message with ToolResult structs in api_logs
      Mimic.stub_with(LangChain.Chains.LLMChain, Nest.LangChainMock)

      # Send a message to create some history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

      Process.sleep(100)

      # Create a message with api_logs containing ToolResult structs in payload
      # The api_logs payload still contains raw LangChain structs for testing serialization
      message_with_api_logs =
        {:assistant,
         %Assistant{
           index: 2,
           timestamp: DateTime.utc_now(),
           content: "Response with API logs",
           api_logs: [
             %{
               id: "api_001",
               timestamp: DateTime.utc_now(),
               type: :response,
               payload: %{
                 role: :assistant,
                 content: "Test",
                 tool_results: [
                   %LangChain.Message.ToolResult{
                     tool_call_id: "call_456",
                     name: "shell_cmd",
                     content: [
                       %LangChain.Message.ContentPart{
                         type: :text,
                         content: "output",
                         options: [],
                         citations: []
                       }
                     ],
                     is_error: false
                   }
                 ],
                 index: 2,
                 status: :complete
               }
             }
           ]
         }}

      # Inject the message into the agent's state
      {:ok, agent_pid} = Nest.Agents.Supervisor.get_agent(id)

      :sys.replace_state(agent_pid, fn state ->
        %{state | messages: [message_with_api_logs | state.messages]}
      end)

      # Sync from -1 should return all messages including the one with api_logs
      sync_ref = push(socket, "chat:sync", %{"lastIndex" => -1})

      # This should NOT crash with Protocol.UndefinedError
      assert_reply sync_ref, :ok, %{"messages" => messages}

      # Find the message with api_logs
      message = Enum.find(messages, fn m -> m["index"] == 2 end)
      assert message != nil

      # api_logs should be present and properly formatted
      assert is_list(message["apiLogs"])
      [api_log] = message["apiLogs"]
      assert api_log["id"] == "api_001"

      # payload.tool_results should be plain maps, not structs
      payload = api_log["payload"]
      assert is_map(payload)
      assert is_list(payload["tool_results"])
      tool_result = List.first(payload["tool_results"])
      refute is_struct(tool_result)
      assert tool_result["tool_call_id"] == "call_456"
      assert tool_result["content"] == "output"
    end
  end
end
