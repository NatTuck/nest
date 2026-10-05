defmodule Nest.Agents.Agent.Turn.LifecycleTest do
  @moduledoc """
  Run-time interrupted-tool recovery: a tool worker that dies without a
  result must be answered with an `is_error` result and the turn must
  continue; a user-cancelled turn must stop without continuing.

  The turn now runs in the Agent process, so these operate directly on
  the Agent state (no stub GenServer peer).
  """

  use ExUnit.Case, async: true
  alias Nest.Agents.Agent.Machine

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Turn.Lifecycle
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  describe "worker_exited/3" do
    test "answers a pending tool_use and continues when a tool worker dies uncancelled" do
      state = state([assistant_tool(1, "call_1")], false)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> Lifecycle.worker_exited(self(), :killed, state) end)

      assert {:noreply, returned} = result
      assert returned.live.turn.active_worker == nil
      assert returned.live.turn.active_worker_kind == nil
      assert_received :iterate
      assert log =~ "lost its tool worker"

      assert {:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "call_1", is_error: true}]}} =
               List.last(returned.chat_state.messages)
    end

    test "a user-cancelled tool death stops instead of continuing" do
      state = state([assistant_tool(1, "call_1")], true)

      assert {:noreply, returned} = Lifecycle.worker_exited(self(), :killed, state)
      refute_received :iterate
      assert Machine.status_for(returned.live.machine) == :idle
    end

    test "an HTTP worker death with no pending tool_use finalizes quietly" do
      base = state([], false)

      state = %{
        base
        | live: %{base.live | turn: %{base.live.turn | active_worker_kind: :http}}
      }

      assert {:noreply, returned} = Lifecycle.worker_exited(self(), :shutdown, state)
      refute_received :iterate
      assert Machine.status_for(returned.live.machine) == :idle
    end
  end

  defp state(messages, cancelled) do
    %Agent{
      name: nil,
      space_id: nil,
      llm_metrics: %Agent.LlmMetrics{
        context_limit: 100_000,
        context_limit_source: :config,
        usage_totals: %{},
        descendant_usage: %{}
      },
      chat_state: %Agent.ChatState{messages: messages, next_message_index: 2},
      live: %Agent.ChatState.Live{
        machine:
          Machine.status_to_machine(
            %Machine{},
            :executing_tools
          ),
        cancelled: cancelled,
        turn: %Agent.ChatState.Live.Turn{
          active_worker: self(),
          active_worker_kind: :tools,
          ctx: %{agent_pid: self(), context_limit: 100_000, tools: [], tool_choice: :auto}
        }
      }
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
end
