defmodule Nest.Agents.Agent.SubAgentTest do
  @moduledoc """
  Unit tests for `Nest.Agents.Agent.SubAgent` — the
  parent-side handlers for `clone_agent` and
  `:child_completed`.

  These tests exercise the *handlers* directly with a
  synthesized `Nest.Agents.Agent.t()` state. The full
  E2E flow (driving LLM calls through MockClient) lives
  in `clone_agent_flow_test.exs`.

  The outstanding-children bookkeeping now lives in the
  machine's `Nest.Agents.Agent.Machine.Children` sub-machine, so
  these tests build running-child entries through
  `Machine.spawn_child/4` rather than poking a struct field.

  ## What's covered

    * `handle_child_completed/4` merges the child's total
      usage into `descendant_usage`, removes the running
      entry, and forwards `:spawn_agent_result` to the
      blocked worker.
    * When `handle_child_completed/4` arrives for an
      unknown child (e.g. double-completion), the
      handler is a no-op (defensive).
    * Cascaded children accumulate into a single
      `descendant_usage` map.

  The "spawn + kick off chat turn" path of
  `handle_spawn_request/3` is exercised end-to-end in
  `clone_agent_flow_test.exs`, so we keep this module
  focused on the receive-side handler.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Children
  alias Nest.Agents.Agent.SubAgent

  describe "handle_child_completed/4" do
    test "merges child usage, drops the running entry, forwards :spawn_agent_result" do
      parent = build_parent_state()
      task_pid = self()
      child_name = "completed-child-#{System.unique_integer([:positive])}"
      state = with_running_child(parent, child_name, task_pid)

      child_total = %{
        Broadcasts.empty_usage_totals()
        | output_tokens: 42,
          total_input_tokens: 100,
          total_tokens: 142
      }

      result = SubAgent.handle_child_completed(state, child_name, "done", child_total)
      assert {:noreply, new_state} = result

      # Forwarded to the worker — the test process is the
      # worker.
      assert_receive {:spawn_agent_result, ^child_name, "done"}, 200

      # Running entry removed; the child is terminal.
      assert Machine.pending_children(new_state.live.machine) == %{}
      assert Children.status(new_state.live.machine.children, child_name) == :completed

      # Usage merged into descendant_usage.
      assert new_state.llm_metrics.descendant_usage.output_tokens == 42
      assert new_state.llm_metrics.descendant_usage.total_input_tokens == 100
      assert new_state.llm_metrics.descendant_usage.total_tokens == 142
    end

    test "no-op for an unknown child name" do
      parent = build_parent_state()

      assert {:noreply, new_state} =
               SubAgent.handle_child_completed(parent, "ghost-child", "ok", %{})

      # The turn settle-loop only rebuilds the (opaque) working ctx; the
      # child bookkeeping and observable status are untouched.
      assert Machine.pending_children(new_state.live.machine) == %{}
      assert new_state.live.machine.children == parent.live.machine.children
      assert Machine.status_for(new_state.live.machine) == Machine.status_for(parent.live.machine)
    end

    test "cascades the merge: descendant usage accumulates across children" do
      parent = build_parent_state()
      task_pid = self()
      child_a = "child-a-#{System.unique_integer([:positive])}"
      child_b = "child-b-#{System.unique_integer([:positive])}"

      state = with_running_child(parent, child_a, task_pid)

      total_a = %{Broadcasts.empty_usage_totals() | output_tokens: 10, total_input_tokens: 50}
      {:noreply, state} = SubAgent.handle_child_completed(state, child_a, "a", total_a)
      assert_receive {:spawn_agent_result, ^child_a, "a"}, 200

      state = with_running_child(state, child_b, task_pid)

      total_b = %{Broadcasts.empty_usage_totals() | output_tokens: 20, total_input_tokens: 70}
      {:noreply, state} = SubAgent.handle_child_completed(state, child_b, "b", total_b)
      assert_receive {:spawn_agent_result, ^child_b, "b"}, 200

      # Cumulative: 10 + 20 = 30 output, 50 + 70 = 120 input.
      assert state.llm_metrics.descendant_usage.output_tokens == 30
      assert state.llm_metrics.descendant_usage.total_input_tokens == 120
    end
  end

  describe "cascade_terminate/1" do
    test "calls the supervisor's cascade_children_only and returns :ok" do
      parent = build_parent_state()
      assert SubAgent.cascade_terminate(parent) == :ok
    end
  end

  describe "handle_child_failed/3 and handle_child_terminated/3" do
    test "handle_child_failed/3 forwards :spawn_agent_error and never archives" do
      parent = build_parent_state()
      task_pid = self()
      child_name = "failed-child-#{System.unique_integer([:positive])}"
      state = with_running_child(parent, child_name, task_pid, true)

      assert {:noreply, new_state} =
               SubAgent.handle_child_failed(state, child_name, {:crashed, "boom"})

      assert_receive {:spawn_agent_error, ^child_name, {:crashed, "boom"}}, 200

      # Slot dropped, terminal, and the child is NOT left queued for
      # archival (the `:failed` terminal transition emits no archive).
      assert Machine.pending_children(new_state.live.machine) == %{}
      assert Children.status(new_state.live.machine.children, child_name) == :failed
    end

    test "handle_child_terminated/3 forwards :spawn_agent_error and never archives" do
      parent = build_parent_state()
      task_pid = self()
      child_name = "terminated-child-#{System.unique_integer([:positive])}"
      state = with_running_child(parent, child_name, task_pid, true)

      assert {:noreply, new_state} =
               SubAgent.handle_child_terminated(state, child_name, :shutdown)

      assert_receive {:spawn_agent_error, ^child_name, :shutdown}, 200
      assert Machine.pending_children(new_state.live.machine) == %{}
      assert Children.status(new_state.live.machine.children, child_name) == :terminated
    end

    test "a failure for an unknown child is a no-op" do
      parent = build_parent_state()

      assert {:noreply, failed} = SubAgent.handle_child_failed(parent, "ghost", :stopped)
      assert failed.live.machine.children == parent.live.machine.children

      assert {:noreply, terminated} = SubAgent.handle_child_terminated(parent, "ghost", :shutdown)
      assert terminated.live.machine.children == parent.live.machine.children
    end
  end

  describe "stop_pending_children/1" do
    test "clears the children sub-machine and walks Supervisor.stop_agent for each running entry" do
      parent = build_parent_state()
      task_pid = self()
      child_a = "stop-child-a-#{System.unique_integer([:positive])}"
      child_b = "stop-child-b-#{System.unique_integer([:positive])}"

      state =
        parent
        |> with_running_child(child_a, task_pid)
        |> with_running_child(child_b, task_pid)

      # The two fake names aren't registered in the live
      # ChildRegistry, so `Supervisor.stop_agent/1` returns
      # `{:error, :not_found}` for each — which the helper
      # discards. The bookkeeping assertions below are what
      # the unit actually pins: the map resets cleanly so a
      # late-arriving `:child_completed` becomes a defensive
      # no-op in `handle_child_completed/4`.
      new_state = SubAgent.stop_pending_children(state)
      assert Machine.pending_children(new_state.live.machine) == %{}
      assert new_state.live.machine.children == Children.new()
      # Other fields are untouched.
      assert new_state.name == state.name

      assert Machine.status_for(new_state.live.machine) ==
               Machine.status_for(state.live.machine)
    end
  end

  # Helpers

  defp with_running_child(state, name, task_pid, archive \\ false) do
    {:ok, _actions, machine} =
      Machine.step(state.live.machine, {:child_spawned, name, task_pid, archive})

    %{state | live: %{state.live | machine: machine}}
  end

  defp build_parent_state do
    %Agent{
      name: "parent-#{System.unique_integer([:positive])}",
      model: %{name: "qwen3.5-plus"},
      client_config: nil,
      vocation_id: 0,
      vocation: nil,
      llm_metrics: %Agent.LlmMetrics{
        context_limit: nil,
        context_limit_source: nil,
        usage_totals: Broadcasts.empty_usage_totals(),
        descendant_usage: Broadcasts.empty_usage_totals()
      },
      chat_state: %Agent.ChatState{}
    }
  end
end
