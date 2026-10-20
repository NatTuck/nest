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

  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  describe "handle_in(chat:stop)" do
    test "is a no-op when no chat is in flight", %{socket: socket} do
      # Agent is idle; stop is a no-op and broadcasts no events.
      ref = push(socket, "chat:stop", %{})
      assert_reply ref, :ok, %{}

      # `:sys.get_state/1` is a synchronous call to the channel: it drains
      # the channel's mailbox, so any `chat:status` the agent broadcast during
      # the stop has already been pushed to this process before it answers.
      # The check below is therefore deterministic rather than a 50 ms window.
      # allowlist: barrier — anchor for refute_received %Phoenix.Socket.Message{}
      _ = :sys.get_state(socket.channel_pid, 1_000)
      refute_received %Phoenix.Socket.Message{event: "chat:status"}
    end

    test "stop mid-stream does not crash the channel", %{socket: socket} do
      # Regression: stopping a running chat turn acks the channel with a
      # bare `:stopped`. The channel used to have no `handle_info` clause
      # for it and crashed, killing the join. Drive a real mid-stream
      # stop, then verify the same socket still serves a channel request
      # (which would hang against a dead channel). The `:stopped` ack is
      # queued to the channel during the stop call and processed before
      # any later push, so this deterministically fails pre-fix.
      MockClient.set_stream_events(for _ <- 1..2000, do: {:text, "x"})

      ref_msg = push(socket, "chat:message", %{"content" => "Start"})
      assert_reply ref_msg, :ok, %{}

      assert_push "chat:delta", _, 1_000

      ref_stop = push(socket, "chat:stop", %{})
      assert_reply ref_stop, :ok, %{}

      # The interrupted turn finalizes and the agent returns to idle. This is
      # the fence for the probe below: without it the probe can legitimately
      # observe "streaming" while finalization is still in flight.
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      # The channel survived the `:stopped` ack: it still answers.
      ref_probe = push(socket, "chat:status", %{})
      assert_reply ref_probe, :ok, %{"status" => "idle"}
    end
  end
end
