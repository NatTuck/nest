defmodule Nest.Agents.Agent.ChatTurn.LifecycleTest do
  @moduledoc """
  Run-time interrupted-tool recovery: a tool worker that dies without a
  result must be answered with an `is_error` result and the turn must
  continue; a user-cancelled turn must stop without continuing.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatTurn.Lifecycle
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  describe "worker_exited/3" do
    test "answers a pending tool_use and continues when a tool worker dies uncancelled" do
      agent = start_agent_stub([assistant_tool(1, "call_1")], false)
      state = state(agent)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:noreply, returned} = Lifecycle.worker_exited(self(), :killed, state)
          assert returned.active_worker == nil
          assert returned.active_worker_kind == nil
          assert_received :iterate
        end)

      assert log =~ "lost its tool worker"

      assert_receive {:append_message,
                      {:tool,
                       %Tool{
                         parts: [%Part.ToolResult{tool_call_id: "call_1", is_error: true}]
                       }}}
    end

    test "a user-cancelled tool death stops instead of continuing" do
      agent = start_agent_stub([assistant_tool(1, "call_1")], true)
      state = state(agent)

      assert {:stop, :normal, _state} = Lifecycle.worker_exited(self(), :killed, state)
      refute_received :iterate
      refute_received {:append_message, _}
    end

    test "an HTTP worker death with no pending tool_use finalizes quietly" do
      agent = start_agent_stub([], false)
      state = %{state(agent) | active_worker_kind: :http}

      assert {:stop, :normal, _state} = Lifecycle.worker_exited(self(), :shutdown, state)
      refute_received :iterate
      refute_received {:append_message, _}
    end
  end

  defp state(agent) do
    %State{
      ctx: %{agent_pid: agent, agent_name: "test-agent"},
      active_worker: self(),
      active_worker_kind: :tools
    }
  end

  defp assistant_tool(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}}],
       api_logs: []
     }}
  end

  defp start_agent_stub(messages, cancelled) do
    parent = self()
    spawn_link(fn -> loop(messages, cancelled, parent) end)
  end

  # A minimal `GenServer.call` peer. The recover path only reads
  # `:get_messages` / `:get_messages_with_cancelled` and appends via
  # `{:append_message, _}`; the stub forwards the append to the test.
  defp loop(messages, cancelled, parent) do
    receive do
      {:"$gen_call", from, :get_messages} ->
        GenServer.reply(from, messages)
        loop(messages, cancelled, parent)

      {:"$gen_call", from, :get_messages_with_cancelled} ->
        GenServer.reply(from, {messages, cancelled})
        loop(messages, cancelled, parent)

      {:"$gen_call", from, {:append_message, msg}} ->
        send(parent, {:append_message, msg})
        GenServer.reply(from, msg)
        loop(messages, cancelled, parent)

      {:"$gen_cast", _msg} ->
        loop(messages, cancelled, parent)
    end
  end
end
