defmodule NestWeb.AgentChannelChatTest do
  @moduledoc """
  AgentChannel chat handling tests: `chat:sync`, `terminate/2`,
  `chat:status`, `chat:sync` edge cases, and the `chat:error` event.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import ExUnit.CaptureLog
  import Mimic

  alias Ecto.Adapters.SQL.Sandbox
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

    test "error event is broadcast when LLM fails" do
      # Capture the model-missing log from `init/1`. The agent
      # boots in `:model_missing` (the test's actual target)
      # because `model` omits `:provider`.
      on_exit(fn -> Process.delete(:test_error_agent_id) end)

      _creation_log =
        capture_log(fn ->
          {:ok, id} =
            Agents.create_agent(
              %{name: "qwen3.5-plus"},
              vocation_id: AgentTestHelpers.vocation_id_for_test()
            )

          Process.put(:test_error_agent_id, id)
          :ok
        end)

      error_agent_id = Process.get(:test_error_agent_id)
      {:ok, error_agent_pid} = Supervisor.get_agent(error_agent_id)

      {:ok, error_agent_pid} = Supervisor.get_agent(error_agent_id)

      :sys.replace_state(error_agent_pid, fn state ->
        %{state | client_config: %{state.client_config | client: MockClient}}
      end)

      # Agent pid needs explicit sandbox access — without it,
      # `Persistence.insert_message/2` blocks indefinitely on
      # the test pid's sandbox checkout.
      Sandbox.allow(Nest.Repo, self(), error_agent_pid)

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
      assert log =~ "chat:error"
      assert log =~ "ChatTurn.run_chat_task/1"
      assert log =~ "model failed"
    end
  end

  describe "handle_in(chat:message) compaction-frozen state rejection" do
    test "rejects chat:message when the agent is :compacting", %{socket: socket, agent_id: id} do
      {:ok, agent_pid} = Supervisor.get_agent(id)

      :sys.replace_state(agent_pid, fn state ->
        %{state | chat_state: %{state.chat_state | status: :compacting}}
      end)

      ref = push(socket, "chat:message", %{"content" => "during compaction"})

      assert_reply ref, :error, %{"reason" => "agent_status_compacting"}
    end

    test "rejects chat:message when the agent is :compaction_failed", %{
      socket: socket,
      agent_id: id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(id)

      :sys.replace_state(agent_pid, fn state ->
        %{state | chat_state: %{state.chat_state | status: :compaction_failed}}
      end)

      ref = push(socket, "chat:message", %{"content" => "after failure"})

      assert_reply ref, :error, %{"reason" => "agent_status_compaction_failed"}
    end

    test "rejects chat:message when the agent is :context_overflow", %{
      socket: socket,
      agent_id: id
    } do
      # `context_overflow` is distinct from the compaction pair:
      # the model can't respond at all, so we still reject the
      # push.
      {:ok, agent_pid} = Supervisor.get_agent(id)

      :sys.replace_state(agent_pid, fn state ->
        %{state | chat_state: %{state.chat_state | status: :context_overflow}}
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
    test "forwards to Agents.retry_compaction/1", %{socket: socket, agent_id: id} do
      {:ok, agent_pid} = Supervisor.get_agent(id)

      # The retry path resumes `pending_user_message`. Set both the
      # status and the held message so Trigger B fires.
      :sys.replace_state(agent_pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
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
      assert {:error, %{"reason" => "agent not found"}} =
               subscribe_and_join(
                 socket(NestWeb.UserSocket),
                 NestWeb.AgentChannel,
                 "agent:nonexistent"
               )
    end
  end

  describe "handle_in(chat:stop)" do
    test "reply is immediate {:ok, %{}} and does not block on the agent", %{socket: socket} do
      # Fire-and-forget: reply goes back immediately; finalization
      # is async. Mid-stream interrupt behavior is in
      # `Nest.Agents.AgentStopTest`; this verifies channel only.
      ref = push(socket, "chat:stop", %{})
      assert_reply ref, :ok, %{}
    end

    test "is a no-op when no chat is in flight", %{socket: socket} do
      # Agent is idle; stop is a no-op and broadcasts no events.
      ref = push(socket, "chat:stop", %{})
      assert_reply ref, :ok, %{}

      refute_receive %Phoenix.Socket.Message{event: "chat:status"}, 50
    end

    test "the agent can run a new turn after a stop", %{socket: socket, agent_id: id} do
      # Send a normal turn, then a no-op stop, then a new turn.
      # The stop must not leave the agent in a broken state.
      MockClient.set_response("First response")

      ref_msg = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref_msg, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 2000
      assert_push "chat:status", %{status: "idle"}, 2000

      # No-op stop on an idle agent.
      ref_stop = push(socket, "chat:stop", %{})
      assert_reply ref_stop, :ok, %{}

      # Second turn works normally.
      MockClient.set_response("After the stop")
      ref2 = push(socket, "chat:message", %{"content" => "Second"})
      assert_reply ref2, :ok, %{}

      assert_push "chat:message", %{"index" => 3, "role" => "user"}, 2000

      assert_push "chat:message",
                  %{"index" => 4, "role" => "assistant", "parts" => parts},
                  2000

      assert [%{"kind" => "text", "text" => content} | _] = parts
      assert content == "After the stop"
      # Sanity: agent still queryable after stop.
      assert {:ok, %{name: ^id}} = Agents.get_info(id)
    end
  end
end
