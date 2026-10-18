defmodule NestWeb.AgentChannelConfigGateTest do
  @moduledoc """
  The agent channel's reply when the supervisor refuses to start the agent,
  split from `NestWeb.AgentChannelTest` to keep that file under the credo cap.

  `Supervisor.get_agent/2` answers `{:error, {:config_file_not_regular, path}}`
  for a workspace `Nest.ConfigFile.error/1` refuses, so every `handle_in/3` that
  reaches for the agent can be handed a reason carrying a detail term.
  `NestWeb.ErrorPayload` is what makes that a reply instead of a
  `Protocol.UndefinedError` inside the channel — which killed the socket and left
  the client with nothing at all.

  The refusals are **stubbed** rather than produced by a real bad workspace: to
  get one for real the agent has to be stopped first, so the supervisor re-reads
  its row from the DB, and the supervisor is an application process — it can only
  see this test's uncommitted rows in shared sandbox mode, which serialises the
  whole suite. What is under test here is the channel's reply path, and the real
  end-to-end refusal is pinned in `Nest.Tools.ShellCmdTest`,
  `Nest.Agents.Agent.InitPrepareTest` and the lobby channel's `edit_agent` and
  `change_model` tests.
  """
  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents
  alias Nest.ConfigFile

  setup :verify_on_exit!

  describe "a config file Nest cannot protect" do
    test "every control-plane entry point answers, rather than killing the socket", %{
      socket: socket
    } do
      path = "/home/nat/proj/AGENTS.md"
      refused = {:error, {:config_file_not_regular, path}}

      stub(Agents, :get_info, fn _space, _name -> refused end)
      stub(Agents, :get_agent_sync, fn _space, _name -> refused end)
      stub(Agents, :get_api_logs, fn _space, _name, _index -> refused end)
      stub(Agents, :change_model, fn _space, _name, _model -> refused end)
      stub(Agents, :reload_agent, fn _space, _name -> refused end)
      stub(Agents, :compact, fn _space, _name, _focus -> refused end)
      stub(Agents, :retry_compaction, fn _space, _name -> refused end)

      # `set_mode/3` answers every error as a *sentence*, because the client shows
      # it verbatim — so its reply is not the wire code.
      stub(Agents, :set_mode, fn _space, _name, _mode ->
        {:error, ConfigFile.error_message(path)}
      end)

      # The channel is a process of its own: a stub set here is invisible to it
      # until it is allowed.
      Mimic.allow(Agents, self(), socket.channel_pid)

      # `change_model` and `set_agent_mode` log the refusal before answering it.
      log =
        capture_log(fn ->
          for {event, payload} <- [
                {"chat:status", %{}},
                {"chat:inbox", %{}},
                {"chat:sync", %{"lastIndex" => -1}},
                {"chat:api-logs", %{"index" => 0}},
                {"chat:message", %{"content" => "hi"}},
                {"chat:compact", %{}},
                {"chat:retry-compaction", %{}},
                {"reload_agent", %{}},
                {"change_model",
                 %{"model" => %{"name" => "qwen3.5-plus", "provider" => "model-studio"}}}
              ] do
            ref = push(socket, event, payload)

            assert_reply ref, :error, %{"reason" => "config_file_not_regular", "path" => ^path}
          end

          ref = push(socket, "set_agent_mode", %{"mode" => "plan"})
          assert_reply ref, :error, %{"reason" => reason}
          assert reason =~ path
          assert reason =~ "is not a regular file"
        end)

      assert log =~ "change_model failed on agent"
      assert log =~ "set_agent_mode failed on agent"
    end
  end
end
