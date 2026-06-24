defmodule NestWeb.AgentChannelTest do
  @moduledoc """
  Core AgentChannel tests: join/3, init payload, message history,
  and the `chat:message` handler.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  setup :verify_on_exit!

  describe "join/3" do
    test "joins agent channel and returns state with messageCount", %{
      socket: socket,
      agent_id: id
    } do
      assert socket.topic == "agent:#{id}"
      assert_push "init", payload
      assert payload["id"] == id
      assert payload["model"][:name] == "qwen3.5-plus"
      assert payload["messageCount"] == 1
      assert payload["status"] == "idle"
      # Init includes partial (nil when not streaming)
      assert Map.has_key?(payload, "partial")
      assert payload["partial"] == nil
      refute Map.has_key?(payload, "messages")
    end

    test "init includes modes, defaultMode, and currentMode", %{socket: _socket} do
      assert_push "init", payload
      # Vocation-less agent defaults to "chat"
      assert payload["modes"] == ["chat"]
      assert payload["defaultMode"] == "chat"
      assert payload["currentMode"] == "chat"
    end

    test "init includes contextLimit, contextLimitSource, and usage", %{socket: _socket} do
      assert_push "init", payload

      # qwen3.5-plus has a configured context-limit of 512_000
      # in test/data/config.toml.
      assert payload["contextLimit"] == 512_000
      assert payload["contextLimitSource"] == "config"
      # No chat has happened yet, so usage is the initial zero map.
      # Note: `assert_push` captures the Erlang term, not the wire
      # format, so the map keys are still atoms here. The wire
      # format (JSON) is what the frontend sees.
      assert payload["usage"] == %{
               input_tokens: 0,
               output_tokens: 0,
               total_tokens: 0,
               reasoning_tokens: 0,
               last_output: 0
             }
    end

    test "init payload includes provider in the model map", %{socket: _socket} do
      assert_push "init", payload

      # The model map must carry both :name and :provider so the
      # frontend can render "provider: model-name" in the chat
      # header (assets/js/pages/ChatPage.jsx).
      assert payload["model"][:name] == "qwen3.5-plus"
      assert payload["model"][:provider] == "model-studio"
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
    test "init reports messageCount = 2 after one chat turn", %{socket: socket, agent_id: id} do
      # The setup's subscribe_and_join already pushed the *first*
      # channel's init (messageCount: 0) into this process's mailbox.
      # Consume it explicitly so the later `assert_push "init"`
      # after the rejoin matches the *new* channel's init, not the
      # stale one. Without this, the assertion sees the setup's
      # messageCount = 0 and the test would pass for the wrong reason.
      assert_push "init", _setup_init, 2000

      # Push one user message; the agent will respond, leaving 2 persisted messages.
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 2000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 2000

      # Drop the first channel and wait for it to actually terminate
      # before rejoining. Monitor + :DOWN is the synchronous Erlang
      # primitive; GenServer.stop/2 is async and would race.
      channel_pid = socket.channel_pid
      monitor_ref = Process.monitor(channel_pid)
      Process.unlink(channel_pid)
      GenServer.stop(channel_pid, :normal)
      assert_receive {:DOWN, ^monitor_ref, :process, ^channel_pid, _}, 1000

      {:ok, _, _new_socket} =
        subscribe_and_join(socket(NestWeb.UserSocket), NestWeb.AgentChannel, "agent:#{id}")

      assert_push "init", payload, 2000
      assert payload["messageCount"] == 3
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

    test "accepts a mode field in the payload", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello", "mode" => "build"})
      assert_reply ref, :ok, %{}

      # The user message broadcast includes the mode (which gets stored
      # in the User struct's metadata).
      assert_push "chat:message", %{"role" => "user"}, 500
    end

    test "omitting mode is allowed (defaults to chat)", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}
      assert_push "chat:message", %{"role" => "user"}, 500
    end

    test "broadcasts user message with index", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Receive user message broadcast first
      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 500

      # Then receive streaming deltas
      assert_push "chat:delta", payload, 500
      assert is_integer(payload["index"])
      assert is_binary(payload["content"])
      assert is_integer(payload["charsStart"])
      assert is_integer(payload["charsEnd"])
    end

    test "chat:status broadcast carries currentMode (sticky mode)", %{socket: socket} do
      # Sending a chat:message updates the agent's `state.mode`
      # to the resolved mode. The status push that transitions
      # to `idle` (the one that unlocks the input) carries the
      # new currentMode so the client can reset the dropdown.
      ref = push(socket, "chat:message", %{"content" => "Hello", "mode" => "chat"})
      assert_reply ref, :ok, %{}

      # The user message lands first, then the LLM streams and
      # finalizes with a chat:status: idle. Drain intermediate
      # broadcasts with `assert_push` and `assert_receive` and
      # then assert the final status carries `currentMode`.
      assert_push "chat:message", %{"role" => "user"}, 500

      # Drain the streaming path. We don't care about each
      # delta — just make sure the assistant message and the
      # idle status both arrive.
      assert_push "chat:message", %{"role" => "assistant"}, 500

      assert_push "chat:status", %{status: "idle", currentMode: "chat"}, 500
    end

    test "calls LLM and broadcasts response with deltas and index", %{socket: socket} do
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # User message is the first chat:message (broadcast by the
      # agent when the chat starts). Then deltas stream. The
      # final chat:message is the assistant. Each is a known
      # broadcast; we use non-blocking receive with `after 0`
      # to drain any extra deltas that landed between the
      # user message and the assistant.
      assert_push "chat:message", %{"role" => "user"}, 500

      # Each chat:delta is a known broadcast. The mock returns
      # one text event → one delta. Verify its shape.
      assert_push "chat:delta", delta, 500
      assert is_integer(delta["index"])
      assert is_binary(delta["content"])
      assert is_integer(delta["charsStart"])
      assert is_integer(delta["charsEnd"])
      assert delta["charsEnd"] > delta["charsStart"]

      assert_push "chat:message", %{"role" => "assistant", "index" => idx}, 500
      assert idx >= 0
    end
  end

  describe "handle_in(chat:status)" do
    test "reply includes currentMode so the client can re-sync after a reconnect",
         %{socket: socket} do
      ref = push(socket, "chat:status", %{})
      assert_reply ref, :ok, payload

      # currentMode must be present so the client can re-sync
      # the dropdown on reconnect / re-fetch. For a vocation-less
      # agent the default is "chat".
      assert payload["currentMode"] == "chat"
    end
  end
end
