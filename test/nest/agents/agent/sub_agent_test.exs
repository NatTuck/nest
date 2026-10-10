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
  these tests build running-child entries through the machine's
  `{:child_spawned, name, archive, target}` event rather than poking a struct
  field.

  ## What's covered

    * `handle_child_completed/4` merges the child's total
      usage into `descendant_usage`, removes the running
      entry, and enqueues the child's answer into the parent's
      own inbox (`kind: :agent`).
    * A failed or stopped child reaches the parent as a runtime
      `:notice` naming the child, so the parent learns the answer
      is not coming instead of waiting it out.
    * When `handle_child_completed/4` arrives for an
      unknown child (e.g. double-completion), the
      handler is a no-op (defensive). A late termination after a
      parent stop is the same no-op, because the stop cleared the
      children map.
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
    test "merges child usage, drops the running entry, and enqueues the answer" do
      parent = build_parent_state()
      child_name = "completed-child-#{System.unique_integer([:positive])}"
      state = with_running_child(parent, child_name)

      child_total = %{
        Broadcasts.empty_usage_totals()
        | output_tokens: 42,
          total_input_tokens: 100,
          total_tokens: 142
      }

      result = SubAgent.handle_child_completed(state, child_name, "done", child_total)
      assert {:noreply, new_state} = result

      # The child's own words land in the parent's own inbox, framed as an
      # agent message: the child said it, so it is not a runtime notice.
      assert [%{from: ^child_name, content: "done", kind: :agent}] = new_state.live.inbox

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
      child_a = "child-a-#{System.unique_integer([:positive])}"
      child_b = "child-b-#{System.unique_integer([:positive])}"

      state = with_running_child(parent, child_a)

      total_a = %{Broadcasts.empty_usage_totals() | output_tokens: 10, total_input_tokens: 50}
      {:noreply, state} = SubAgent.handle_child_completed(state, child_a, "a", total_a)

      state = with_running_child(state, child_b)

      total_b = %{Broadcasts.empty_usage_totals() | output_tokens: 20, total_input_tokens: 70}
      {:noreply, state} = SubAgent.handle_child_completed(state, child_b, "b", total_b)

      # Both answers are queued, in completion order.
      assert [%{from: ^child_a, content: "a"}, %{from: ^child_b, content: "b"}] = state.live.inbox

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
    test "a failed or stopped child reaches the parent as a runtime notice" do
      for {handle, tag, reason, status, news} <- [
            {&SubAgent.handle_child_failed/3, "failed", {:crashed, "boom"}, :failed,
             "failed before it answered: {:crashed, \"boom\"}"},
            {&SubAgent.handle_child_terminated/3, "stopped", :shutdown, :terminated,
             "was stopped before it answered: :shutdown"}
          ] do
        parent = build_parent_state()
        child_name = "#{tag}-child-#{System.unique_integer([:positive])}"
        state = with_running_child(parent, child_name, true)

        assert {:noreply, new_state} = handle.(state, child_name, reason)

        # The runtime speaks, not the child — a `:notice` (rendered bare),
        # naming the child and quoting why the answer is not coming. The
        # child's slot is dropped and terminal; whether a terminal transition
        # emits an archive is pinned in `Machine.ChildrenTest`.
        assert [%{from: ^child_name, kind: :notice, content: content}] = new_state.live.inbox
        assert content == "Child agent #{child_name} #{news}"

        assert Machine.pending_children(new_state.live.machine) == %{}
        assert Children.status(new_state.live.machine.children, child_name) == status
      end
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
      child_a = "stop-child-a-#{System.unique_integer([:positive])}"
      child_b = "stop-child-b-#{System.unique_integer([:positive])}"

      state =
        parent
        |> with_running_child(child_a)
        |> with_running_child(child_b)

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

    test "a child that dies after the stop is a no-op, not a second notice" do
      # The parent's Stop clears the children map, so the registry `:DOWN` that
      # follows it finds nothing to apply: no notice, no second delivery. The
      # notice a parent *does* get for a stopped child is the one the child's
      # own death produces while it is still registered.
      parent = build_parent_state()
      child = "late-child-#{System.unique_integer([:positive])}"
      stopped = parent |> with_running_child(child) |> SubAgent.stop_pending_children()

      assert {:noreply, after_event} = SubAgent.handle_child_terminated(stopped, child, :shutdown)

      assert after_event.live.inbox == []
      assert after_event.live.machine.children == Children.new()
    end
  end

  # Helpers

  defp with_running_child(state, name, archive \\ false) do
    {:ok, _actions, machine} =
      Machine.step(state.live.machine, {:child_spawned, name, archive, nil})

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
      # Mid-turn, as a parent is whenever it spawned the child it is hearing
      # back from. (An *idle* parent also drains the answer into a turn — the
      # wake-up the boundary-delivery test pins — which needs a real agent and a
      # database; these are unit tests for the handler's bookkeeping.)
      chat_state: %Agent.ChatState{},
      live: %Agent.ChatState.Live{machine: %Machine{phase: :executing_tools}}
    }
  end
end
