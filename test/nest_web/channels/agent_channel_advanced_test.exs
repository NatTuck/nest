defmodule NestWeb.AgentChannelAdvancedTest do
  @moduledoc """
  AgentChannel advanced tests: agent process isolation, API logs in
  `chat:message` events, and tool result serialization.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolResult

  setup :verify_on_exit!

  describe "agent process isolation" do
    test "agent process does not capture channel pid", %{socket: _socket, agent_id: id} do
      {:ok, _pid} = Agents.Supervisor.get_agent(id)
    end

    test "messages are not lost on channel rejoin", %{socket: socket, agent_id: id} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 500
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 500

      # Sync verifies state via the channel's sync handler (a sync
      # GenServer.call). The reply includes the agent's messages.
      sync_ref = push(socket, "chat:sync", %{"lastIndex" => -1})
      assert_reply sync_ref, :ok, %{"messages" => messages, "messageCount" => msg_count}

      assert length(messages) == 3
      assert msg_count >= 3

      Process.unlink(socket.channel_pid)
      channel_pid = socket.channel_pid
      mon = Process.monitor(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^mon, :process, ^channel_pid, _reason}, 500

      {:ok, _, new_socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      sync_ref2 = push(new_socket, "chat:sync", %{"lastIndex" => -1})
      assert_reply sync_ref2, :ok, %{"messages" => messages2, "messageCount" => msg_count2}

      assert length(messages2) >= 2
      assert msg_count2 >= 2

      Process.unlink(new_socket.channel_pid)
      GenServer.stop(new_socket.channel_pid, :normal)
    end

    test "sync returns correct messages after multiple rejoins", %{socket: socket, agent_id: id} do
      ref1 = push(socket, "chat:message", %{"content" => "Message 1"})
      assert_reply ref1, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 500
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 500

      channel_pid = socket.channel_pid
      mon = Process.monitor(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^mon, :process, ^channel_pid, _reason}, 500

      {:ok, _, socket2} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      ref_sync = push(socket2, "chat:sync", %{"lastIndex" => -1})
      assert_reply ref_sync, :ok, %{"messages" => messages, "messageCount" => last_complete}

      assert messages != []
      assert last_complete >= 0

      channel_pid = socket2.channel_pid
      mon = Process.monitor(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^mon, :process, ^channel_pid, _reason}, 500

      {:ok, _, socket3} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      ref_sync2 = push(socket3, "chat:sync", %{"lastIndex" => -1})
      assert_reply ref_sync2, :ok, %{"messages" => messages2, "messageCount" => last_complete2}

      assert messages2 != []
      assert last_complete2 == last_complete
    end
  end

  describe "API logs in chat:message events" do
    test "API requests and responses are broadcast with correct message indices in two-round conversation",
         %{socket: socket} do
      # === Round 1 ===
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Each chat:message broadcast is a known message. The user
      # message is broadcast first (empty api_logs), then
      # re-broadcast after the request log is attached. Match the
      # re-broadcast version with non-empty apiLogs.
      assert_push "chat:message", %{"index" => 1, "role" => "user", "apiLogs" => [user1_log]}, 500

      assert_push "chat:message",
                  %{"index" => 2, "role" => "assistant", "apiLogs" => [asst1_log]},
                  500

      assert user1_log["type"] == "request"
      assert user1_log["id"] == "001.000"
      assert is_map(user1_log["payload"])

      assert asst1_log["type"] == "response"
      assert asst1_log["id"] == "002.000"
      assert is_map(asst1_log["payload"])

      # === Round 2 ===
      ref2 = push(socket, "chat:message", %{"content" => "How are you?"})
      assert_reply ref2, :ok, %{}

      assert_push "chat:message", %{"index" => 3, "role" => "user", "apiLogs" => [user2_log]}, 500

      assert_push "chat:message",
                  %{"index" => 4, "role" => "assistant", "apiLogs" => [asst2_log]},
                  500

      assert user2_log["type"] == "request"
      assert user2_log["id"] == "003.000"

      assert asst2_log["type"] == "response"
      assert asst2_log["id"] == "004.000"
    end

    test "API call payload contains conversation history and tool calls", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "First message"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user", "apiLogs" => [user_req]}, 500

      assert_push "chat:message",
                  %{"index" => 2, "role" => "assistant", "apiLogs" => [asst_resp]},
                  500

      assert user_req["id"] == "001.000"
      assert is_map(user_req["payload"])
      assert user_req["timestamp"] != nil

      assert asst_resp["id"] == "002.000"
      assert is_map(asst_resp["payload"])
      assert asst_resp["timestamp"] != nil
    end

    test "tool messages have API request logs from continuation", %{socket: socket} do
      MockClient.set_tool_response(%{
        text: "I'll run that command",
        tool_calls: [
          %{
            id: "call_shell_001",
            name: "shell_cmd",
            arguments: %{"command" => "echo test"}
          }
        ]
      })

      MockClient.set_response("Done")

      ref = push(socket, "chat:message", %{"content" => "Run a command"})
      assert_reply ref, :ok, %{}

      # The tool message is re-broadcast after its api_logs are
      # populated. Match the version with non-empty apiLogs.
      assert_push "chat:message", %{"index" => 3, "role" => "tool", "apiLogs" => [tool_req]}, 500

      assert_push "chat:message",
                  %{"index" => 4, "role" => "assistant", "apiLogs" => [_asst_resp]},
                  500

      assert tool_req["type"] == "request"
      assert tool_req["id"] == "003.000"
      assert is_map(tool_req["payload"])
      assert tool_req["timestamp"] != nil

      MockClient.clear()
    end
  end

  describe "tool result serialization" do
    test "tool results are converted to plain maps for JSON serialization", %{socket: socket} do
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
               arguments: %{"command" => "ls -la"},
               is_error: false
             }
           ],
           api_logs: []
         }}

      send(socket.channel_pid, {:chat_message, tool_result_message})

      assert_push "chat:message", payload, 500

      assert payload["index"] == 2
      assert payload["role"] == "tool"
      assert payload["content"] == nil
      assert is_list(payload["toolResults"])
      assert length(payload["toolResults"]) == 1

      tool_result = List.first(payload["toolResults"])

      assert is_map(tool_result)
      refute is_struct(tool_result)
      assert tool_result["tool_call_id"] == "call_123"
      assert tool_result["name"] == "shell_cmd"
      assert tool_result["content"] == "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 ."
      assert tool_result["arguments"] == %{"command" => "ls -la"}
      assert tool_result["is_error"] == false
    end

    test "chat:sync handles messages with ToolResult structs", %{socket: socket, agent_id: id} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 500
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 500

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
               arguments: %{"command" => "ls -la"},
               is_error: false
             }
           ],
           api_logs: []
         }}

      {:ok, agent_pid} = Supervisor.get_agent(id)

      :sys.replace_state(agent_pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | messages: [tool_result_message | state.chat_state.messages]
            }
        }
      end)

      sync_ref = push(socket, "chat:sync", %{"lastIndex" => -1})
      assert_reply sync_ref, :ok, %{"messages" => messages}

      tool_message = Enum.find(messages, fn m -> m["role"] == "tool" end)
      assert tool_message != nil

      assert is_list(tool_message["toolResults"])
      tool_result = List.first(tool_message["toolResults"])
      assert is_map(tool_result)
      refute is_struct(tool_result)
      assert tool_result["tool_call_id"] == "call_123"
      assert tool_result["content"] == "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 ."
      assert tool_result["arguments"] == %{"command" => "ls -la"}
    end

    test "chat:sync handles messages with ToolResult structs in api_logs", %{
      socket: socket,
      agent_id: id
    } do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 500
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 500

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
                   %{
                     "tool_call_id" => "call_456",
                     "name" => "shell_cmd",
                     "content" => "output",
                     "is_error" => false
                   }
                 ],
                 index: 2,
                 status: :complete
               }
             }
           ]
         }}

      {:ok, agent_pid} = Supervisor.get_agent(id)

      :sys.replace_state(agent_pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | messages: [message_with_api_logs | state.chat_state.messages]
            }
        }
      end)

      sync_ref = push(socket, "chat:sync", %{"lastIndex" => -1})
      assert_reply sync_ref, :ok, %{"messages" => messages}

      message = Enum.find(messages, fn m -> m["index"] == 2 end)
      assert message != nil

      assert is_list(message["apiLogs"])
      [api_log] = message["apiLogs"]
      assert api_log["id"] == "api_001"

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
