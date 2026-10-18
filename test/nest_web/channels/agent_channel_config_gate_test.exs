defmodule NestWeb.AgentChannelConfigGateTest do
  @moduledoc """
  The agent channel's reply when the supervisor refuses to start the agent,
  split from `NestWeb.AgentChannelTest` to keep that file under the credo cap.

  `Supervisor.get_agent/2` answers `{:error, {:config_file_not_regular, path, type}}`
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

  setup :verify_on_exit!

  describe "a config file Nest cannot protect" do
    # One push per **reply shape**, not per event: `chat:compact`,
    # `chat:retry-compaction`, `chat:stop` and `chat:loop-detected-ok` all go
    # through `Replies.reply_control/2`, so the two here stand for all four.
    test "every reply shape answers, rather than killing the socket", %{
      socket: socket
    } do
      path = "/home/nat/proj/AGENTS.md"
      refused = {:error, {:config_file_not_regular, path, :symlink}}

      stub(Agents, :get_info, fn _space, _name -> refused end)
      stub(Agents, :get_agent_sync, fn _space, _name -> refused end)
      stub(Agents, :get_api_logs, fn _space, _name, _index -> refused end)
      stub(Agents, :change_model, fn _space, _name, _model -> refused end)
      stub(Agents, :reload_agent, fn _space, _name -> refused end)
      stub(Agents, :compact, fn _space, _name, _focus -> refused end)
      stub(Agents, :retry_compaction, fn _space, _name -> refused end)

      # The channel is a process of its own: a stub set here is invisible to it
      # until it is allowed.
      Mimic.allow(Agents, self(), socket.channel_pid)

      # `change_model` logs the refusal before answering it.
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

            assert_reply ref, :error, %{
              "reason" => "config_file_not_regular",
              "path" => ^path,
              "type" => "symlink"
            }
          end
        end)

      assert log =~ "change_model failed on agent"
    end

    test "chat:message keeps its own spelling for the two refusals it renames", %{
      socket: socket
    } do
      Mimic.allow(Agents, self(), socket.channel_pid)

      stub(Agents, :get_info, fn _space, _name -> {:error, :not_found} end)
      ref = push(socket, "chat:message", %{"content" => "hi"})
      assert_reply ref, :error, %{"reason" => "agent_not_found"}

      # An archived agent is its own code rather than "not found": the row exists,
      # it is stopped, and it must not be resurrected to answer.
      stub(Agents, :get_info, fn _space, _name -> {:error, :archived} end)
      ref = push(socket, "chat:message", %{"content" => "hi"})
      assert_reply ref, :error, %{"reason" => "agent_archived"}
    end

    test "the join names the file, rather than answering agent_unavailable" do
      # Opening a chat for an agent that is not running in a bad workspace is the
      # most common way a user meets this refusal. Without the clause in
      # `join_refusal/2` it lands in the catch-all as `agent_unavailable`, which
      # names no file — and the existing catch-all test still passes, because it
      # stubs a different error.
      path = "/home/nat/proj/.nest"

      stub(Agents, :get_agent, fn _space_id, _name ->
        {:error, {:config_file_not_regular, path, :symlink}}
      end)

      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => Process.get(:agent_test_token)})

      assert {:error,
              %{
                "reason" => "config_file_not_regular",
                "path" => ^path,
                "type" => "symlink"
              }} = subscribe_and_join(connected, NestWeb.AgentChannel, "agent:1:any-missing")
    end
  end
end
