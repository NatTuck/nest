defmodule NestWeb.AgentChannelChatStopTest do
  @moduledoc """
  `handle_in(chat:stop)` tests, split from
  `NestWeb.AgentChannelChatTest` to keep that file under
  the credo 500-line cap. Same setup shape — these tests
  join the agent channel under a fresh test user.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.Agents
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

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

    test "stop mid-stream does not crash the channel", %{socket: socket} do
      # Regression: stopping a running ChatTurn acks the channel with a
      # bare `:stopped`. The channel used to have no `handle_info` clause
      # for it and crashed, killing the join. Drive a real mid-stream
      # stop, then verify the same socket still serves a channel request
      # (which would hang against a dead channel). The `:stopped` ack is
      # queued to the channel during the stop call and processed before
      # any later push, so this deterministically fails pre-fix.
      MockClient.set_stream_events(for _ <- 1..2000, do: {:text, "x"})

      ref_msg = push(socket, "chat:message", %{"content" => "Start"})
      assert_reply ref_msg, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 2000
      assert_push "chat:delta", _, 2000

      ref_stop = push(socket, "chat:stop", %{})
      assert_reply ref_stop, :ok, %{}

      # The interrupted turn finalizes and the agent returns to idle.
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # The channel survived the `:stopped` ack: it still answers.
      ref_probe = push(socket, "chat:status", %{})
      assert_reply ref_probe, :ok, %{"status" => "idle"}
    end

    test "the agent can run a new turn after a stop", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
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
      assert {:ok, %{name: ^id}} = Agents.get_info(space_id, id)
    end
  end
end
