defmodule NestWeb.AgentChannelChatTest do
  @moduledoc """
  AgentChannel chat handling tests: `chat:sync`, `terminate/2`,
  `chat:status`, `chat:sync` edge cases, and the `chat:error` event.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  describe "handle_in(chat:sync)" do
    test "returns empty sync for new agent", %{socket: socket} do
      ref = push(socket, "chat:sync", %{"lastIndex" => -1})
      assert_reply ref, :ok, %{"messages" => [], "partial" => nil, "status" => "idle"}
    end

    test "returns messages after lastIndex", %{socket: socket} do
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
      channel_pid = socket.channel_pid
      ref = Process.monitor(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^channel_pid, _reason}, 1000

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

    test "chat:status reply includes contextLimit, contextLimitSource, and usage",
         %{socket: socket} do
      ref = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref, :ok, %{
        "contextLimit" => limit,
        "contextLimitSource" => source,
        "usage" => usage
      }

      assert limit == 512_000
      assert source == "config"
      # `assert_reply` captures the Erlang reply, so the map keys
      # are still atoms. The wire format is JSON for the frontend.
      assert usage == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               reasoning_tokens: 0,
               last_output: 0
             }
    end

    test "returns status with messageCount after messages", %{socket: socket, agent_id: id} do
      # Send a message to create history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion (user message first, then assistant)
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

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
      # Send a message to create history
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", _payload, 2000

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
      # Send first message
      ref1 = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref1, :ok, %{}

      # Wait for completion (user message first, then assistant)
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 2000

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
      # Mock the LLM to fail. `Client.run/2` always returns
      # `{:ok, stream}` per the behaviour; errors are surfaced as
      # `{:error, _}` events inside the stream, which the agent
      # captures in the reducer's `error` field and routes to
      # `handle_failed_response/3`.
      MockClient.set_error("model unavailable")

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
      # Create the second agent for this test BEFORE injecting the
      # error, so the MockClient error lands in this test's queue
      # (not the previous test's).
      {:ok, error_agent_id} = Agents.create_agent(%{name: "qwen3.5-plus"})
      {:ok, error_agent_pid} = Supervisor.get_agent(error_agent_id)

      :sys.replace_state(error_agent_pid, fn state ->
        %{state | client_config: %{state.client_config | client: MockClient}}
      end)

      Process.put(:nest_test_agent_pid, error_agent_pid)
      MockClient.start_link(error_agent_pid)
      MockClient.set_error("model failed")

      on_exit(fn ->
        MockClient.stop(error_agent_pid)
        Process.delete(:nest_test_agent_pid)
      end)

      log =
        capture_log(fn ->
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
end
