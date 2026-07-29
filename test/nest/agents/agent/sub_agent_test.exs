defmodule Nest.Agents.Agent.SubAgentTest do
  @moduledoc """
  Unit tests for `Nest.Agents.Agent.SubAgent` — the
  parent-side handlers for `clone_agent` and
  `:child_completed`.

  These tests exercise the *handlers* directly with a
  synthesized `Nest.Agents.Agent.t()` state. The full
  E2E flow (driving LLM calls through MockClient) lives
  in `clone_agent_flow_test.exs`.

  ## What's covered

    * `handle_child_completed/4` merges the child's total
      usage into `descendant_usage`, removes the pending
      entry, and forwards `:clone_agent_result` to the
      blocked worker.
    * When `handle_child_completed/4` arrives for an
      unknown child (e.g. double-completion), the
      handler is a no-op (defensive).
    * Cascaded children accumulate into a single
      `descendant_usage` map.

  The "spawn + kick off chat turn" path of
  `handle_clone_request/3` is exercised end-to-end in
  `clone_agent_flow_test.exs`, so we keep this module
  focused on the receive-side handler.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.SubAgent

  describe "handle_child_completed/4" do
    test "merges child usage, drops the pending entry, forwards :clone_agent_result" do
      parent = build_parent_state()
      task_pid = self()
      child_name = "completed-child-#{System.unique_integer([:positive])}"

      state =
        %{parent | chat_state: %{parent.chat_state | pending_children: %{child_name => task_pid}}}

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
      assert_receive {:clone_agent_result, ^child_name, "done"}, 200

      # Pending entry removed.
      assert new_state.chat_state.pending_children == %{}

      # Usage merged into descendant_usage.
      assert new_state.llm_metrics.descendant_usage.output_tokens == 42
      assert new_state.llm_metrics.descendant_usage.total_input_tokens == 100
      assert new_state.llm_metrics.descendant_usage.total_tokens == 142
    end

    test "no-op for an unknown child name" do
      parent = build_parent_state()

      assert {:noreply, ^parent} =
               SubAgent.handle_child_completed(parent, "ghost-child", "ok", %{})
    end

    test "cascades the merge: descendant usage accumulates across children" do
      parent = build_parent_state()
      task_pid = self()
      child_a = "child-a-#{System.unique_integer([:positive])}"
      child_b = "child-b-#{System.unique_integer([:positive])}"

      state =
        %{parent | chat_state: %{parent.chat_state | pending_children: %{child_a => task_pid}}}

      total_a = %{Broadcasts.empty_usage_totals() | output_tokens: 10, total_input_tokens: 50}
      {:noreply, state} = SubAgent.handle_child_completed(state, child_a, "a", total_a)
      assert_receive {:clone_agent_result, ^child_a, "a"}, 200

      state = put_in(state.chat_state.pending_children[child_b], task_pid)

      total_b = %{Broadcasts.empty_usage_totals() | output_tokens: 20, total_input_tokens: 70}
      {:noreply, state} = SubAgent.handle_child_completed(state, child_b, "b", total_b)
      assert_receive {:clone_agent_result, ^child_b, "b"}, 200

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

  describe "stop_pending_children/1" do
    test "clears pending_children and walks Supervisor.stop_agent for each entry" do
      parent = build_parent_state()
      task_pid = self()
      child_a = "stop-child-a-#{System.unique_integer([:positive])}"
      child_b = "stop-child-b-#{System.unique_integer([:positive])}"

      state =
        %{
          parent
          | chat_state: %{
              parent.chat_state
              | pending_children: %{child_a => task_pid, child_b => task_pid}
            }
        }

      # The two fake names aren't registered in the live
      # ChildRegistry, so `Supervisor.stop_agent/1` returns
      # `{:error, :not_found}` for each — which the helper
      # discards. The bookkeeping assertions below are what
      # the unit actually pins: the map resets cleanly so a
      # late-arriving `:child_completed` becomes a defensive
      # no-op in `handle_child_completed/4`.
      new_state = SubAgent.stop_pending_children(state)
      assert new_state.chat_state.pending_children == %{}
      # Other fields are untouched.
      assert new_state.name == state.name
      assert new_state.chat_state.status == state.chat_state.status
    end
  end

  # Helpers

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
