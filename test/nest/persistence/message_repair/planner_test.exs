defmodule Nest.Persistence.MessageRepair.PlannerTest do
  @moduledoc """
  Unit tests for the pure repair planner: pairing repairs, simple
  alternation repairs, partial tool-result merging, and recursive
  clone renumbering. No database.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence.MessageRepair.Planner

  describe "pairing repairs" do
    test "a trailing orphan gets one is_error tool result" do
      plan =
        plan([agent(1, next: 3)], %{
          1 => [row(1, 1, system(0)), row(2, 1, user(1)), row(3, 1, assistant_tool(2, "call_1"))]
        })

      assert [{1, 3}] = insert_indices(plan)
      assert plan.residual_violations == %{}
      assert plan.original_violations[1] != nil
      assert [%{runtime: {:tool, %Tool{parts: [result]}}}] = plan.inserts
      assert %Part.ToolResult{tool_call_id: "call_1", is_error: true} = result
      assert plan.agent_updates[1].next_message_index == 4
    end

    test "an orphan followed by a user message gets a tool result and an ack" do
      plan =
        plan([agent(1, next: 4)], %{
          1 => [
            row(1, 1, system(0)),
            row(2, 1, user(1)),
            row(3, 1, assistant_tool(2, "x")),
            row(4, 1, user(3))
          ]
        })

      assert [{1, 3}, {1, 4}] = insert_indices(plan)
      assert Enum.map(plan.inserts, & &1.runtime) |> Enum.map(&elem(&1, 0)) == [:tool, :assistant]
      assert plan.residual_violations == %{}
      assert Enum.any?(plan.renumbers, &(&1.id == 4 and &1.index == 5))
      assert plan.agent_updates[1].next_message_index == 6
    end

    test "a partial tool result is rewritten to include the missing results" do
      plan =
        plan([agent(1, next: 2)], %{
          1 => [row(1, 1, assistant_tools(0, ["a", "b"])), row(2, 1, tool_result(1, "a"))]
        })

      assert plan.inserts == []
      assert [%{id: 2, agent_id: 1}] = plan.rewrites
      assert plan.residual_violations == %{}

      {:tool, %Tool{parts: parts}} = hd(plan.rewrites).runtime
      assert Enum.map(parts, & &1.tool_call_id) == ["a", "b"]
      assert Enum.any?(parts, &(&1.tool_call_id == "b" and &1.is_error))
    end
  end

  describe "alternation repairs" do
    test "two consecutive user messages get an assistant between them" do
      plan =
        plan([agent(1, next: 3)], %{
          1 => [row(1, 1, system(0)), row(2, 1, user(1)), row(3, 1, user(2))]
        })

      assert [{1, 2}] = insert_indices(plan)
      assert [%{runtime: {:assistant, %Assistant{}}}] = plan.inserts
      assert plan.residual_violations == %{}
    end

    test "two consecutive assistant messages get a user between them" do
      plan =
        plan([agent(1, next: 2)], %{
          1 => [row(1, 1, assistant_text(0)), row(2, 1, assistant_text(1))]
        })

      assert [{1, 1}] = insert_indices(plan)
      assert [%{runtime: {:user, %User{}}}] = plan.inserts
      assert plan.residual_violations == %{}
    end
  end

  describe "clone renumbering" do
    test "an insert into the parent prefix shifts the child fork and own indices" do
      parent_rows = [
        row(1, 1, system(0)),
        row(2, 1, user(1)),
        row(3, 1, user(2)),
        row(4, 1, assistant_tool(3, "spawn"))
      ]

      child_rows = [row(5, 2, tool_result(4, "spawn")), row(6, 2, assistant_text(5))]

      plan =
        plan(
          [agent(1, next: 4), agent(2, parent: 1, fork: 4, next: 6)],
          %{1 => parent_rows, 2 => child_rows}
        )

      assert MapSet.member?(plan.changed_agents, 2)
      assert plan.agent_updates[2].fork_message_index == 5
      assert plan.agent_updates[2].next_message_index == 7

      assert Enum.any?(plan.renumbers, &(&1.id == 5 and &1.index == 5))
      assert Enum.any?(plan.renumbers, &(&1.id == 6 and &1.index == 6))
      assert plan.residual_violations == %{}
    end

    test "a fresh child (no fork) is unaffected by a parent insert" do
      parent_rows = [row(1, 1, user(0)), row(2, 1, user(1))]

      plan =
        plan(
          [agent(1, next: 2), agent(2, parent: 1, fork: nil, next: 1)],
          %{1 => parent_rows, 2 => [row(3, 2, system(0))]}
        )

      refute MapSet.member?(plan.changed_agents, 2)
      refute Map.has_key?(plan.agent_updates, 2)
    end
  end

  test "a healthy sequence plans no writes" do
    plan =
      plan([agent(1, next: 2)], %{1 => [row(1, 1, system(0)), row(2, 1, user(1))]})

    assert plan.inserts == []
    assert plan.rewrites == []
    assert plan.renumbers == []
    assert plan.changed_agents == MapSet.new()
    assert plan.original_violations == %{}
    assert plan.residual_violations == %{}
  end

  # ---- helpers ----

  defp plan(agents, rows), do: Planner.plan(agents, rows)

  defp insert_indices(plan) do
    plan.inserts
    |> Enum.sort_by(& &1.index)
    |> Enum.map(&{&1.agent_id, &1.index})
  end

  defp agent(id, opts) do
    struct(PersistedAgent, %{
      id: id,
      name: "agent-#{id}",
      space_id: 1,
      model: %{},
      next_message_index: Keyword.get(opts, :next, 0),
      last_compaction_index: Keyword.get(opts, :last, -1),
      fork_message_index: Keyword.get(opts, :fork),
      parent_id: Keyword.get(opts, :parent)
    })
  end

  defp row(id, agent_id, runtime) do
    runtime
    |> then(&PersistedMessage.from_runtime(agent_id, &1))
    |> Map.merge(%{id: id, inserted_at: ~U[2026-01-01 00:00:00Z]})
    |> then(&struct(PersistedMessage, &1))
  end

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(index), do: {:user, %User{index: index, parts: [%Part.Text{text: "hi"}]}}

  defp assistant_text(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "ok"}], api_logs: []}}
  end

  defp assistant_tool(index, id), do: assistant_tools(index, [id])

  defp assistant_tools(index, ids) do
    parts = Enum.map(ids, &%Part.ToolUse{id: &1, name: "shell-cmd", arguments: %{}})
    {:assistant, %Assistant{index: index, parts: parts, api_logs: []}}
  end

  defp tool_result(index, id) do
    {:tool,
     %Tool{
       index: index,
       parts: [
         %Part.ToolResult{tool_call_id: id, name: "shell-cmd", content: "ok", is_error: false}
       ],
       api_logs: []
     }}
  end
end
