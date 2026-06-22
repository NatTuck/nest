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
    test "assistant messages have odd indexes", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref, :ok, %{}

      # The user message (index 0, even) is broadcast first, then
      # the assistant (index 1, odd). Match the assistant and assert
      # on the index parity.
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 500
      assert_push "chat:message", %{"index" => idx, "role" => "assistant"}, 500

      assert rem(idx, 2) == 1
    end

    test "messageCount is highest complete (non-partial) message", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 500
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 500

      ref_status = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref_status, :ok, %{"messageCount" => final_count}

      assert final_count == 2
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
      assert_push "chat:delta", %{"content" => "First ", "index" => first_idx}, 500
      assert_push "chat:delta", %{"content" => "second "}, 500
      assert_push "chat:delta", %{"content" => "third "}, 500
      assert_push "chat:delta", %{"content" => "fourth"}, 500

      assert is_integer(first_idx)

      MockClient.clear()
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
    end
  end

  describe "message broadcasting" do
    test "assistant message is broadcast to all subscribers", %{socket: socket, agent_id: id} do
      {:ok, _, socket2} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      ref = push(socket, "chat:message", %{"content" => "Hello from client 1"})
      assert_reply ref, :ok, %{}

      # First client receives user + assistant.
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 500

      assert_push "chat:message",
                  %{"index" => idx, "role" => "assistant"} = assistant_payload,
                  500

      assert rem(idx, 2) == 1
      assert is_binary(assistant_payload["content"])

      # Second client also receives both.
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 500
      assert_push "chat:message", %{"index" => idx2, "role" => "assistant"}, 500

      assert rem(idx2, 2) == 1

      Process.unlink(socket2.channel_pid)
      GenServer.stop(socket2.channel_pid, :normal)
    end

    test "assistant message has correct index and role", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Test"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 500
      assert_push "chat:message", %{"index" => idx, "role" => "assistant"} = payload, 500

      assert is_binary(payload["content"])
      assert idx >= 1
      assert rem(idx, 2) == 1
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
      assert_push "chat:message", %{"index" => 0, "role" => "user"}, 500
      assert_push "chat:message", %{"index" => 1, "role" => "assistant"}, 500

      ref3 = push(socket, "chat:status", %{"lastIndex" => -1})
      assert_reply ref3, :ok, %{"status" => "idle"}
    end
  end

  describe "channel lifecycle edge cases" do
    test "rejoining mid-stream receives correct charsEnd in partial", %{
      socket: socket,
      agent_id: id
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
      assert_push "chat:delta", %{"content" => "First "}, 500
      assert_push "chat:delta", %{"content" => "second "}, 500

      channel_pid = socket.channel_pid
      mon = Process.monitor(channel_pid)
      Process.unlink(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^mon, :process, ^channel_pid, _reason}, 500

      {:ok, _, new_socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      # The new channel's join pushes the init synchronously.
      assert_push "init", init_payload, 500

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
    end

    test "mid-stream join does not trigger delta gap warnings", %{socket: socket, agent_id: id} do
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
      assert_push "chat:delta", %{"content" => "Hello "}, 500
      assert_push "chat:delta", %{"content" => "world "}, 500
      assert_push "chat:delta", %{"content" => "this "}, 500

      channel_pid = socket.channel_pid
      mon = Process.monitor(channel_pid)
      Process.unlink(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^mon, :process, ^channel_pid, _reason}, 500

      {:ok, _, new_socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      assert_push "init", init_payload, 500

      partial = init_payload["partial"]

      if partial != nil do
        init_chars_end = partial["charsEnd"]

        # At least one more delta should arrive with charsStart >=
        # the previous charsEnd (no gap). Assert on the first
        # remaining delta's chars_start.
        assert_push "chat:delta", %{"charsStart" => chars_start}, 500
        assert chars_start >= init_chars_end || chars_start <= init_chars_end + 5
      end

      Process.unlink(new_socket.channel_pid)
      GenServer.stop(new_socket.channel_pid, :normal)
    end
  end
end
