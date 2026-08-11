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
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  describe "handle_in(chat:sync)" do
    test "returns empty sync for new agent", %{socket: socket} do
      # New agent has a single system message at index 0; sync
      # from lastIndex=-1 returns that one.
      ref = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref, :ok, %{"messages" => [system_msg], "partial" => nil, "status" => "idle"}

      assert system_msg["role"] == "system"
    end

    test "returns messages after lastIndex", %{socket: socket} do
      ref1 = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref1, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 2000

      # Sync from current tip: no new messages.
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => 2})
      assert_reply ref_sync, :ok, %{"messages" => [], "partial" => nil, "status" => "idle"}

      ref2 = push(socket, "chat:message", %{"content" => "Second"})
      assert_reply ref2, :ok, %{}

      assert_push "chat:message", %{"index" => 3, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 4, "role" => "assistant"}, 2000

      # Sync from index 2: messages 3 and 4.
      ref_sync2 = push(socket, "chat:sync", %{"lastIndex" => 2})

      assert_reply ref_sync2, :ok, %{
        "messages" => messages,
        "partial" => _partial,
        "status" => "idle"
      }

      assert length(messages) == 2
      assert Enum.all?(messages, fn m -> m["index"] > 1 end)

      assert_receive {:chat_status, %{status: "idle"}}, 500
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
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 2000

      # Sync after completion - partial should be nil again
      ref_sync2 = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref_sync2, :ok, %{
        "messages" => _messages,
        "partial" => partial,
        "status" => "idle"
      }

      assert partial == nil

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end
  end

  describe "terminate/2" do
    test "cleans up channel subscription", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      # Simulate disconnect by leaving the channel
      Process.unlink(socket.channel_pid)
      channel_pid = socket.channel_pid
      ref = Process.monitor(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^channel_pid, _reason}, 1000

      # Agent should still exist (no auto-terminate)
      assert {:ok, _} = Agents.get_info(space_id, id)
    end
  end

  describe "handle_in(chat:status)" do
    test "returns status payload matching init format", %{
      socket: socket,
      agent_id: id
    } do
      ref = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref, :ok, %{
        "name" => status_name,
        "model" => model,
        "messageCount" => last_index,
        "status" => status
      }

      assert status_name == id
      assert model["name"] == "qwen3.5-plus"
      assert last_index == 1
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
      # `context_input_tokens` is the system prompt's estimated
      # size — non-zero so the chip displays a meaningful fill
      # rate from page load.
      assert usage == %{
               input_tokens: 0,
               cache_read_input_tokens: 0,
               cache_creation_input_tokens: 0,
               context_input_tokens: usage.context_input_tokens,
               last_output: 0,
               output_tokens: 0,
               total_input_tokens: 0,
               total_cache_read_input_tokens: 0,
               total_cache_creation_input_tokens: 0,
               total_tokens: 0,
               reasoning_tokens: 0
             }

      assert usage.context_input_tokens > 0
    end

    test "returns status with messageCount after messages", %{socket: socket, agent_id: id} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 2000

      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref_status, :ok, %{
        "name" => status_name,
        "messageCount" => last_index,
        "status" => status
      }

      assert status_name == id
      assert last_index >= 0
      assert status == "idle"

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "returns streaming status during LLM response", %{socket: socket} do
      # Start streaming
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 2000

      # After completion, status should be back to "idle"
      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref_status, :ok, %{"status" => "idle"}

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "returns error when agent not found", %{socket: _socket} do
      # Connect a fresh socket with a valid token, then try to
      # join a topic that doesn't exist — `Agents.get_agent/1`
      # returns `:not_found`, the channel rejects the join.
      token = Process.get(:agent_test_token)
      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

      assert {:error, %{"reason" => "agent not found"}} =
               subscribe_and_join(
                 connected,
                 NestWeb.AgentChannel,
                 "agent:1:nonexistent"
               )
    end
  end

  describe "chat:sync edge cases" do
    test "returns empty messages when lastIndex exceeds server's messageCount", %{
      socket: socket
    } do
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

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "sync response includes messageCount field", %{socket: socket} do
      ref = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref, :ok, reply

      assert reply["messageCount"] == 1
    end

    test "sync with lastIndex: -1 returns all complete messages", %{socket: socket} do
      ref1 = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref1, :ok, %{}

      # Wait for completion (user message first, then assistant)
      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 2000

      # Sync with -1 should return all messages (user + assistant)
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref_sync, :ok, %{
        "messages" => messages,
        "messageCount" => last_complete_index
      }

      # Should have both user (0) and assistant (1) messages
      assert length(messages) >= 2
      assert last_complete_index >= 1

      assert_receive {:chat_status, %{status: "idle"}}, 500
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
          assert payload["index"] == 2
          assert is_binary(payload["content"])
          assert payload["content"] =~ "unavailable" or payload["content"] =~ "error"
        end)

      # Verify the error was logged with the correct message
      assert log =~ "chat:error"
      assert log =~ "ChatTurn.run_chat_task/1"
      assert log =~ "model unavailable"
    end

    test "error event is broadcast when LLM fails", %{user: user} do
      # Stub the model probe so the agent boots in
      # `:model_missing`. The `start_agent/1` helper handles
      # Sandbox.allow + Mimic.allow + `on_exit`
      # `Supervisor.stop_agent/1` cleanup; we keep the
      # `:sys.replace_state` + MockClient.set_error sequence
      # because the agent needs `MockClient` as its runtime
      # client (the recovery flow uses an inert one) and we
      # need to script an error response.
      Nest.Agents.Agent.Config
      |> stub(:create_client_config, fn _model ->
        {:error, %Nest.ChatModel.ModelNotFoundError{message: "x"}}
      end)

      _creation_log =
        capture_log(fn ->
          {error_agent_pid, error_agent_id} =
            AgentTestHelpers.start_agent(%{
              name: "error-agent-#{System.unique_integer([:positive])}",
              model: %{name: "qwen3.5-plus"},
              vocation_id: AgentTestHelpers.vocation_id_for_test(),
              created_by_user_id: user.id
            })

          :sys.replace_state(error_agent_pid, fn state ->
            %{state | client_config: %{state.client_config | client: MockClient}}
          end)

          Process.put(:nest_test_agent_pid, error_agent_pid)
          MockClient.set_error("model failed")

          Process.put(:test_error_agent_id, error_agent_id)
          error_space_id = AgentTestHelpers.current_space_id()
          Process.put(:test_error_agent_space_id, error_space_id)

          log =
            capture_log(fn ->
              # Connect to the new agent using the same test
              # user's token (the error_agent is owned by them).
              token = Process.get(:agent_test_token)
              {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

              {:ok, _, error_socket} =
                subscribe_and_join(
                  connected,
                  NestWeb.AgentChannel,
                  "agent:#{Process.get(:test_error_agent_space_id)}:#{Process.get(:test_error_agent_id)}"
                )

              ref = push(error_socket, "chat:message", %{"content" => "Trigger error"})
              assert_reply ref, :ok, %{}

              # Wait for error broadcast
              assert_push "chat:error", error_payload, 2000
              assert error_payload["index"] >= 0
              assert is_binary(error_payload["content"])
            end)

          # Verify the error was logged with the correct message
          assert log =~ "chat:error"
          assert log =~ "ChatTurn.run_chat_task/1"
          assert log =~ "model failed"
        end)
    end
  end

  describe "handle_in(chat:message) compaction-frozen state rejection" do
    test "rejects chat:message when the agent is :compacting", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      :sys.replace_state(agent_pid, fn state ->
        %{state | live: %{state.live | status: :compacting}}
      end)

      ref = push(socket, "chat:message", %{"content" => "during compaction"})

      assert_reply ref, :error, %{"reason" => "agent_status_compacting"}
    end

    test "rejects chat:message when the agent is :compaction_failed", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      :sys.replace_state(agent_pid, fn state ->
        %{state | live: %{state.live | status: :compaction_failed}}
      end)

      ref = push(socket, "chat:message", %{"content" => "after failure"})

      assert_reply ref, :error, %{"reason" => "agent_status_compaction_failed"}
    end

    test "rejects chat:message when the agent is :context_overflow", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      # `context_overflow` is distinct from the compaction pair:
      # the model can't respond at all, so we still reject the
      # push.
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      :sys.replace_state(agent_pid, fn state ->
        %{state | live: %{state.live | status: :context_overflow}}
      end)

      ref = push(socket, "chat:message", %{"content" => "this won't fit"})

      assert_reply ref, :error, %{"reason" => "agent_status_context_overflow"}
    end

    test "accepts chat:message when the agent is idle", %{socket: socket} do
      # No `:sys.replace_state` — agent defaults to :idle after join.
      MockClient.set_response("Response")

      ref = push(socket, "chat:message", %{"content" => "Hello"})

      assert_reply ref, :ok, %{}
      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 2000

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end
  end

  describe "handle_in(chat:retry-compaction)" do
    test "forwards to Agents.retry_compaction/1", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      # The retry path resumes `pending_user_message`. Set both the
      # status and the held message so Trigger B fires.
      :sys.replace_state(agent_pid, fn state ->
        %{
          state
          | live: %{
              state.live
              | status: :compaction_failed,
                pending_user_message: {"Hello", "chat"}
            }
        }
      end)

      ref = push(socket, "chat:retry-compaction", %{})

      assert_reply ref, :ok, %{}

      assert_receive {:chat_status, %{status: "compacting"}}, 500
    end

    test "returns error when agent does not exist", %{socket: _socket} do
      token = Process.get(:agent_test_token)
      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

      assert {:error, %{"reason" => "agent not found"}} =
               subscribe_and_join(
                 connected,
                 NestWeb.AgentChannel,
                 "agent:1:nonexistent"
               )
    end
  end
end
