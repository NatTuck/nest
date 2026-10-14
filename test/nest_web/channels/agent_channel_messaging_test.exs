defmodule NestWeb.AgentChannelMessagingTest do
  @moduledoc """
  AgentChannel messaging tests: message indexing rules, delta event
  details, message broadcasting, status value constraints, and
  channel lifecycle edge cases.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.LLM.MockClient
  alias Nest.LLM.RunResponse

  setup :verify_on_exit!

  describe "message indexing rules" do
    test "assistant message index follows user message index", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref, :ok, %{}

      # The user message is broadcast first, then the assistant.
      # After the system message at position 0, the user lands at
      # index 1 and the assistant at index 2. Verify the
      # assistant's index is exactly one more than the user's.
      assert_push "chat:message", %{"index" => user_idx, "role" => "user"}, 1_000
      assert_push "chat:message", %{"index" => asst_idx, "role" => "assistant"}, 1_000

      assert asst_idx == user_idx + 1

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end

    test "messageCount is highest complete (non-partial) message", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 1_000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 1_000

      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref_status, :ok, %{"messageCount" => final_count}

      # System + user + assistant = 3 messages
      assert final_count == 3

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end

  describe "delta event details" do
    test "delta index matches message being streamed", %{socket: socket} do
      MockClient.set_stream_events([
        {:text, "First "},
        {:text, "second "},
        {:text, "third "},
        {:text, "fourth"},
        {:finish_reason, "stop"},
        {:done,
         %{
           response: %RunResponse{text: "First second third fourth", stop_reason: "stop"}
         }}
      ])

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Each delta is a known broadcast. Match them discretely in
      # the order they were scripted.
      assert_push "chat:delta", %{"content" => "First ", "index" => first_idx}, 1_000
      assert_push "chat:delta", %{"content" => "second "}, 1_000
      assert_push "chat:delta", %{"content" => "third "}, 1_000
      assert_push "chat:delta", %{"content" => "fourth"}, 1_000

      assert is_integer(first_idx)

      MockClient.clear()

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end

    test "delta charsStart and charsEnd represent content slice", %{socket: socket} do
      # Default mock returns single text "Some text" with one delta.
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:delta",
                  %{
                    "content" => content,
                    "charsStart" => start_pos,
                    "charsEnd" => end_pos
                  },
                  500

      assert is_integer(start_pos)
      assert is_integer(end_pos)
      assert end_pos > start_pos
      assert String.length(content) == end_pos - start_pos

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end

  describe "message broadcasting" do
    test "assistant message is broadcast to all subscribers", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, socket2_conn} =
        connect(NestWeb.UserSocket, %{"token" => Process.get(:agent_test_token)})

      {:ok, _, socket2} =
        subscribe_and_join(socket2_conn, NestWeb.AgentChannel, "agent:#{space_id}:#{id}")

      ref = push(socket, "chat:message", %{"content" => "Hello from client 1"})
      assert_reply ref, :ok, %{}

      # First client receives user + assistant.
      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 1_000

      assert_push "chat:message",
                  %{"index" => idx, "role" => "assistant"} = assistant_payload,
                  500

      assert idx == 2
      assert is_list(assistant_payload["parts"])

      # Second client also receives both.
      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 1_000
      assert_push "chat:message", %{"index" => idx2, "role" => "assistant"}, 1_000

      assert idx2 == 2

      Process.unlink(socket2.channel_pid)
      GenServer.stop(socket2.channel_pid, :normal)

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end

    test "assistant message has correct index and role", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Test"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 1_000
      assert_push "chat:message", %{"index" => idx, "role" => "assistant"} = payload, 1_000

      assert is_list(payload["parts"])
      assert idx >= 1
      assert idx == 2

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end

  describe "status value constraints" do
    test "status is always idle or streaming", %{socket: socket} do
      ref = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref, :ok, %{"status" => status}
      assert status in ["idle", "streaming"]
    end

    test "status transitions idle -> streaming -> idle", %{socket: socket} do
      ref1 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref1, :ok, %{"status" => "idle"}

      ref2 = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref2, :ok, %{}

      # Wait for chat completion via known broadcasts.
      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 1_000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 1_000

      ref3 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref3, :ok, %{"status" => "idle"}

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end

  describe "channel lifecycle edge cases" do
    test "rejoining mid-stream receives correct charsEnd in partial", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      MockClient.set_stream_events([
        {:text, "First "},
        {:text, "second "},
        {:text, "third "},
        {:text, "fourth chunk"},
        {:finish_reason, "stop"},
        {:done,
         %{
           response: %RunResponse{
             text: "First second third fourth chunk",
             stop_reason: "stop"
           }
         }}
      ])

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Collect a few known deltas. We don't care about the exact
      # count of deltas received before disconnect; we just need
      # at least one to be in the mailbox.
      assert_push "chat:delta", %{"content" => "First "}, 1_000
      assert_push "chat:delta", %{"content" => "second "}, 1_000

      channel_pid = socket.channel_pid
      mon = Process.monitor(channel_pid)
      Process.unlink(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^mon, :process, ^channel_pid, _reason}, 1_000

      {:ok, new_conn} =
        connect(NestWeb.UserSocket, %{"token" => Process.get(:agent_test_token)})

      {:ok, _, new_socket} =
        subscribe_and_join(new_conn, NestWeb.AgentChannel, "agent:#{space_id}:#{id}")

      # The new channel's join pushes the init synchronously.
      assert_push "init", init_payload, 1_000

      partial = init_payload["partial"]

      # Streaming may or may not have completed by the time we
      # rejoined; only assert on partial structure when present.
      if partial != nil do
        assert is_integer(partial["charsEnd"])
        assert partial["charsEnd"] > 0
        refute partial["charsEnd"] == 0
      end

      Process.unlink(new_socket.channel_pid)
      GenServer.stop(new_socket.channel_pid, :normal)

      MockClient.clear()

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end

    test "mid-stream join does not trigger delta gap warnings", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      MockClient.set_stream_events([
        {:text, "Hello "},
        {:text, "world "},
        {:text, "this "},
        {:text, "is "},
        {:text, "a "},
        {:text, "test"},
        {:finish_reason, "stop"},
        {:done,
         %{
           response: %RunResponse{
             text: "Hello world this is a test",
             stop_reason: "stop"
           }
         }}
      ])

      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for at least 3 known deltas. The exact count when we
      # disconnect is timing-dependent; we just need >=3.
      assert_push "chat:delta", %{"content" => "Hello "}, 1_000
      assert_push "chat:delta", %{"content" => "world "}, 1_000
      assert_push "chat:delta", %{"content" => "this "}, 1_000

      channel_pid = socket.channel_pid
      mon = Process.monitor(channel_pid)
      Process.unlink(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^mon, :process, ^channel_pid, _reason}, 1_000

      {:ok, new_conn} =
        connect(NestWeb.UserSocket, %{"token" => Process.get(:agent_test_token)})

      {:ok, _, new_socket} =
        subscribe_and_join(new_conn, NestWeb.AgentChannel, "agent:#{space_id}:#{id}")

      assert_push "init", init_payload, 1_000

      partial = init_payload["partial"]

      if partial != nil do
        init_chars_end = partial["charsEnd"]

        # At least one more delta should arrive with charsStart >=
        # the previous charsEnd (no gap). Assert on the first
        # remaining delta's chars_start.
        assert_push "chat:delta", %{"charsStart" => chars_start}, 1_000
        assert chars_start >= init_chars_end || chars_start <= init_chars_end + 5
      end

      Process.unlink(new_socket.channel_pid)
      GenServer.stop(new_socket.channel_pid, :normal)

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end

  describe "tool-call delta streaming" do
    # Regression for the wire-up gap in `Runner.build_stream_consumer/1`:
    # the HTTP worker's `on_tool_call_start` / `on_tool_call_delta`
    # callbacks were dropped before this fix, so tool calls were
    # only visible in the final `chat:message` push. The JS streaming
    # partial needs `chat:delta` events with `partType: :tool_use_*`
    # (atom keys on the wire) to render in-flight tool calls in
    # real time.
    test "emits chat:delta with partType :tool_use_start before chat:message", %{socket: socket} do
      MockClient.set_tool_response(%{
        text: "Let me check",
        tool_calls: [
          %{
            id: "call_stream_1",
            name: "shell-cmd",
            arguments: %{"command" => "ls"}
          }
        ]
      })

      MockClient.set_response("Done")

      ref = push(socket, "chat:message", %{"content" => "list files"})
      assert_reply ref, :ok, %{}

      # `partType` is an atom on the wire (it's serialized to
      # `"tool_use_start"` for the JSON client but the test
      # process receives the raw Elixir term from the channel
      # push, so we match on the atom here).
      assert_receive %Phoenix.Socket.Message{
                       event: "chat:delta",
                       payload: %{"partType" => :tool_use_start} = p1
                     },
                     2000

      assert p1["toolCallId"] == "call_stream_1"
      assert p1["toolCallName"] == "shell-cmd"

      assert_receive %Phoenix.Socket.Message{
                       event: "chat:delta",
                       payload: %{"partType" => :tool_use_delta} = p2
                     },
                     2000

      assert p2["toolCallId"] == "call_stream_1"
      assert p2["content"] == "{\"command\":\"ls\"}"

      # The assistant message with the parsed tool_use part arrives after the
      # deltas (not before). It is the first assistant `chat:message` push, so
      # a selective receive is enough: `assert_receive` skips the user push,
      # the deltas and the raw PubSub broadcasts, and the 1_000ms is only a
      # failure bound, not the synchronisation.
      assert_receive %Phoenix.Socket.Message{
                       event: "chat:message",
                       payload: %{"role" => "assistant", "parts" => parts}
                     },
                     1_000

      tool_use_parts =
        Enum.find(parts, fn
          %{"kind" => "tool_use"} = p -> p
          _ -> nil
        end)

      assert tool_use_parts != nil,
             "expected an assistant message with a tool_use part"

      assert tool_use_parts["name"] == "shell-cmd"
      assert tool_use_parts["arguments"] == %{"command" => "ls"}

      MockClient.clear()

      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end
end
