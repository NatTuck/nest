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
      assert returned.live.machine.work.active_worker == nil
      assert returned.live.machine.work.active_worker_kind == nil
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
        | live: %{
            base.live
            | machine: %{
                base.live.machine
                | work: %{base.live.machine.work | active_worker_kind: :http}
              }
          }
      }

      assert {:noreply, returned} = Lifecycle.worker_exited(self(), :shutdown, state)
      refute_received :iterate
      assert Machine.status_for(returned.live.machine) == :idle
    end
  end

  describe "stop/2" do
    test "enters :stopping, acks the channel, arms the bounded timer, keeps the worker ref" do
      worker =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      ref = make_ref()
      machine = Machine.to_chat_generating(%Machine{})

      work = %Agent.Machine.Work{
        active_worker: worker,
        active_worker_kind: :http,
        worker_ref: ref,
        worker_kind: :http,
        ctx: %{context_limit: 1}
      }

      state = agent_state(%{machine | work: work})

      stopped = Lifecycle.stop(state, self())

      assert_received :stopped
      assert Machine.stopping?(stopped.live.machine)
      assert stopped.live.cancelled
      assert is_reference(stopped.live.machine.stop_timer)
      assert stopped.live.machine.work.active_worker == worker
      assert stopped.live.machine.work.worker_ref == ref
      assert stopped.live.machine.work.worker_kind == nil
      assert stopped.live.machine.work.active_worker_kind == nil

      # A second stop is a no-op: it must not arm a second timer or
      # trigger a second terminal transition.
      again = Lifecycle.stop(stopped, self())
      assert again.live.machine.stop_timer == stopped.live.machine.stop_timer

      Process.cancel_timer(stopped.live.machine.stop_timer)
    end

    test "a stop on an already-idle agent is a no-op" do
      state =
        agent_state(Machine.to_idle(%Machine{}))
        |> put_work(%Agent.Machine.Work{ctx: nil})

      assert Lifecycle.stop(state, self()) == state
      refute_received :stopped
    end

    test "worker_exited while :stopping is a no-op" do
      work = %Agent.Machine.Work{active_worker: self(), worker_kind: nil, worker_ref: make_ref()}
      state = agent_state(%{Machine.to_stopping(%Machine{}) | work: work})

      assert {:noreply, ^state} = Lifecycle.worker_exited(self(), :killed, state)
    end
  end

  defp agent_state(machine) do
    %Agent{
      name: nil,
      space_id: nil,
      llm_metrics: %Agent.LlmMetrics{},
      chat_state: %Agent.ChatState{},
      live: %Agent.ChatState.Live{machine: machine}
    }
  end

  defp put_work(state, work) do
    %{state | live: %{state.live | machine: %{state.live.machine | work: work}}}
  end

  defp state(messages, cancelled) do
    machine =
      Machine.status_to_machine(%Machine{}, :executing_tools)

    work = %Agent.Machine.Work{
      active_worker: self(),
      active_worker_kind: :tools,
      ctx: %{agent_pid: self(), context_limit: 100_000, tools: [], tool_choice: :auto}
    }

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
        machine: %{machine | work: work},
        cancelled: cancelled
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
