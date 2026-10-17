defmodule NestWeb.AgentChannelModeTest do
  @moduledoc """
  The `set_agent_mode` event: the human's mode selector.

  This is the one path that may *raise* a mode — the human is above the rule that
  bounds an agent's own changes (`Nest.Agents.Agent.ModeAuthority`) — and the
  change applies immediately, because the human's selection is persisted rather
  than riding a message. A busy agent refuses it: a mode applies at a settle, so
  a turn already running is under the old one.

  Split out of `NestWeb.AgentChannelTest` (credo's source-file cap).
  """

  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  describe "handle_in(set_agent_mode)" do
    test "switches the agent's mode, announces it and replies ok", %{
      socket: socket,
      space_id: space_id,
      agent_id: id
    } do
      ref = push(socket, "set_agent_mode", %{"mode" => "plan"})
      assert_reply ref, :ok, %{}

      # The change is the runtime's own notice pair in the transcript (the human
      # is above the monotone rule, so this is the one path that may raise a
      # mode)...
      assert_push "chat:message", %{"role" => "user", "parts" => [%{"text" => notice}]}, 500
      assert notice =~ "Your mode is now `plan`"
      assert notice =~ "set by the user"

      # ...it is persisted (so a restart restores it) and it is the mode the
      # agent is now in...
      {:ok, pid} = Nest.Agents.Supervisor.get_agent(space_id, id)
      assert Nest.Agents.Agent.get_public_info(pid, 1_000).current_mode == "plan"

      # ...and a client that re-syncs reads it back off `chat:status`.
      ref = push(socket, "chat:status", %{})
      assert_reply ref, :ok, payload
      assert payload["currentMode"] == "plan"
    end

    test "a refusal reaches the client as a reason", %{socket: socket} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ref = push(socket, "set_agent_mode", %{"mode" => "chat"})
          assert_reply ref, :error, %{"reason" => reason}
          assert reason =~ "not a mode"
        end)

      # The refusal is logged rather than silent, so assert on the line the
      # capture would otherwise only hide.
      assert log =~ "set_agent_mode failed"
    end

    test "a payload without a mode is refused as invalid", %{socket: socket} do
      ref = push(socket, "set_agent_mode", %{})
      assert_reply ref, :error, %{"reason" => "invalid_payload"}
    end
  end
end
