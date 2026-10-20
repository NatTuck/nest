defmodule NestWeb.AgentChannelAdvancedTest do
  @moduledoc """
  AgentChannel advanced tests: the message history across a channel rejoin,
  the reply debt on the wire, API logs in `chat:message` events and over
  `chat:api-logs`, and tool result serialization.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  # `:sys.replace_state/3` with an explicit timeout: OTP's default is 5000 ms,
  # well over both this suite's 500 ms test bound and ExUnit's 2000 ms per-test
  # ceiling, so a wedged server surfaces as the stuck call it is rather than as
  # a test timeout (#21).
  defp replace_state(pid, fun), do: :sys.replace_state(pid, fun, 1_000)

  setup :verify_on_exit!

  describe "channel rejoin" do
    test "messages are not lost on channel rejoin", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user", "origin" => "human"}, 1_000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 1_000

      assert_receive {:chat_status, %{status: "idle"}}, 1_000

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
      assert_receive {:DOWN, ^mon, :process, ^channel_pid, _reason}, 1_000

      {:ok, new_conn} =
        connect(NestWeb.UserSocket, %{"token" => Process.get(:agent_test_token)})

      {:ok, _, new_socket} =
        subscribe_and_join(new_conn, NestWeb.AgentChannel, "agent:#{space_id}:#{id}")

      sync_ref2 = push(new_socket, "chat:sync", %{"lastIndex" => -1})
      assert_reply sync_ref2, :ok, %{"messages" => messages2, "messageCount" => msg_count2}

      assert length(messages2) >= 2
      assert msg_count2 >= 2

      Process.unlink(new_socket.channel_pid)
      GenServer.stop(new_socket.channel_pid, :normal)
    end
  end

  describe "the reply debt on the wire" do
    test "init and chat:status carry owedReplies, and a debt shows up on both", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      # intentional: the debt reaches the browser (issue #31 decision 15 — state
      # the user cannot see is state we are hiding). Both carriers are asserted
      # because a reconnect may only see one: the join payload and the
      # `chat:status` reply. `[]` when nothing is owed, never nil and never
      # absent, so a missing field can never render as "no debt".
      assert_push "init", init_payload
      assert init_payload["owedReplies"] == []

      ref = push(socket, "chat:status", %{})
      assert_reply ref, :ok, %{"owedReplies" => []}

      {:ok, pid} = Supervisor.get_agent(space_id, id)

      replace_state(pid, fn state ->
        %{
          state
          | live: %{state.live | machine: Machine.owe_replies(state.live.machine, ["peer"])}
        }
      end)

      ref = push(socket, "chat:status", %{})
      assert_reply ref, :ok, %{"owedReplies" => ["peer"]}

      # Discharge the debt before the test ends: the teardown stops the agent,
      # and a stop with an unpaid reply logs the accepted loss of it.
      replace_state(pid, fn state ->
        %{state | live: %{state.live | machine: Machine.discharge_all(state.live.machine)}}
      end)
    end
  end

  describe "API logs in chat:message events" do
    test "assistant message carries exactly one response log (no request/history payload)",
         %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "First message"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user", "apiLogs" => user_logs}, 1_000
      assert user_logs == []

      assert_push "chat:message",
                  %{"index" => 2, "role" => "assistant", "apiLogs" => [asst_resp]},
                  500

      assert asst_resp["type"] == "response"
      assert asst_resp["id"] == "002.000"
      assert is_map(asst_resp["payload"])
      assert asst_resp["timestamp"] != nil

      # The response log is the real API response only — it must never
      # contain the request's message history.
      refute Map.has_key?(asst_resp["payload"], "messages"),
             "response log payload must not contain the request message history"

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end

    test "tool messages have empty api_logs; assistant messages carry response logs", %{
      socket: socket
    } do
      MockClient.set_tool_response(%{
        text: "I'll run that command",
        tool_calls: [
          %{
            id: "call_shell_001",
            name: "shell-cmd",
            arguments: %{"command" => "echo test"}
          }
        ]
      })

      MockClient.set_response("Done")

      ref = push(socket, "chat:message", %{"content" => "Run a command"})
      assert_reply ref, :ok, %{}

      # The tool-call assistant is stored complete with its response log.
      assert_push "chat:message",
                  %{"role" => "assistant", "apiLogs" => [asst1_log]},
                  500

      assert asst1_log["type"] == "response"

      # Tool messages no longer carry request api_logs — they're
      # rebuilt on demand when the user expands the API logs widget.
      assert_push "chat:message",
                  %{"role" => "tool", "apiLogs" => tool_logs},
                  500

      assert tool_logs == []

      assert_push "chat:message",
                  %{"role" => "assistant", "parts" => [%{"kind" => "text", "text" => "Done"}]},
                  500

      MockClient.clear()

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end

  describe "chat:api-logs fetch" do
    test "returns the stored response log for an assistant message", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 1_000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 1_000
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      logs_ref = push(socket, "chat:api-logs", %{"index" => 2})
      assert_reply logs_ref, :ok, %{"apiLogs" => [log]}

      assert log["type"] == "response"
      assert is_map(log["payload"])
    end

    test "rebuilds a synthetic request log for a user message", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user", "apiLogs" => []}, 1_000
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      logs_ref = push(socket, "chat:api-logs", %{"index" => 1})
      assert_reply logs_ref, :ok, %{"apiLogs" => [log]}

      assert log["type"] == "request"
      assert is_map(log["payload"])
      assert Map.has_key?(log["payload"], "messages")
    end

    test "returns an error for a message with no logs (never a silent empty list)", %{
      socket: socket
    } do
      # Index 0 is the system message, which never carries logs.
      logs_ref = push(socket, "chat:api-logs", %{"index" => 0})
      assert_reply logs_ref, :error, %{"reason" => "no_logs"}
    end

    test "returns not_found for a missing message index", %{socket: socket} do
      logs_ref = push(socket, "chat:api-logs", %{"index" => 999})
      assert_reply logs_ref, :error, %{"reason" => "not_found"}
    end
  end

  describe "tool result serialization" do
    test "tool results are converted to plain maps for JSON serialization", %{socket: socket} do
      tool_result_message =
        {:tool,
         %Tool{
           index: 2,
           timestamp: DateTime.utc_now(),
           parts: [
             %Part.ToolResult{
               tool_call_id: "call_123",
               name: "shell-cmd",
               content: "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 .",
               arguments: %{"command" => "ls -la"},
               is_error: false
             }
           ],
           api_logs: []
         }}

      send(socket.channel_pid, {:chat_message, tool_result_message})

      assert_push "chat:message", payload, 1_000

      assert payload["index"] == 2
      assert payload["role"] == "tool"
      assert length(payload["parts"]) == 1

      part = List.first(payload["parts"])

      assert part["kind"] == "tool_result"
      assert part["toolCallId"] == "call_123"
      assert part["name"] == "shell-cmd"
      assert part["content"] == "total 4\ndrwxrwxr-x 1 user user 18 May 29 10:49 ."
      assert part["arguments"] == %{"command" => "ls -la"}
      assert part["isError"] == false
    end

    test "chat:sync handles messages with ToolResult structs in api_logs", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 1_000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 1_000

      message_with_api_logs =
        {:assistant,
         %Assistant{
           index: 2,
           timestamp: DateTime.utc_now(),
           parts: [%Part.Text{text: "Response with API logs"}],
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
                     "name" => "shell-cmd",
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

      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      replace_state(agent_pid, fn state ->
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

      [api_log] = message["apiLogs"]
      assert api_log["id"] == "api_001"

      payload = api_log["payload"]
      tool_result = List.first(payload["tool_results"])
      assert tool_result["tool_call_id"] == "call_456"
      assert tool_result["content"] == "output"

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end
end
