defmodule Nest.Persistence.AgentCompaction.PlannerTest do
  @moduledoc """
  Unit tests for the pure offline-compaction planner: active prefix
  and orphan detection, budgets, safe-boundary chunking, oversize
  truncation, and the system-prompt headroom fallback. No database,
  no LLM.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.PersistedAgent
  alias Nest.Messages.Assistant
  alias Nest.Messages.Compaction
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence.AgentCompaction.Planner
  alias Nest.Tokens.Estimator

  describe "active prefix and orphans" do
    test "plans a contiguous active prefix" do
      agent = agent(next: 4, boundary: -1)
      full = [system_msg(0), user(1), assistant(2), user(3)]

      assert {:ok, plan} = Planner.plan(agent, full, ctx())

      assert plan.archived_count == 4
      assert plan.marker_index == 4
      assert plan.orphan_count == 0
      assert plan.slice == [system_msg(0), user(1), assistant(2), user(3)]
      assert plan.compaction_count == 1
      assert plan.chunk_budget > 0
      assert plan.summary_budget > 0
      assert plan.chunks != []
    end

    test "detects rows after a gap and rows past next_message_index as orphans" do
      agent = agent(next: 6, boundary: -1)
      full = [system_msg(0), user(1), assistant(2), user(4), assistant(5), user(6)]

      assert {:ok, plan} = Planner.plan(agent, full, ctx())

      assert plan.archived_count == 3
      assert plan.orphan_count == 3
      assert Planner.orphan_from(plan) == 3
      assert Enum.map(plan.slice, &index/1) == [0, 1, 2]
    end

    test "compaction_count includes markers at or below the boundary" do
      marker = {:compaction, %Compaction{index: 1, archived_count: 1, compaction_count: 1}}
      agent = agent(next: 4, boundary: 1)
      full = [system_msg(0), marker, system_msg(2), user(3)]

      assert {:ok, plan} = Planner.plan(agent, full, ctx())
      assert plan.compaction_count == 2
      assert plan.archived_count == 2
    end

    test "nothing to compact when the only active row is the system prompt" do
      assert {:error, :nothing_to_compact} =
               Planner.plan(agent(next: 1, boundary: -1), [system_msg(0)], ctx())
    end

    test "errors on a gap before the active prefix" do
      assert {:error, :active_prefix_gap} =
               Planner.plan(agent(next: 3, boundary: -1), [user(1), assistant(2)], ctx())
    end

    test "builds the new system and summary rows and the orphan boundary" do
      full = [system_msg(0), user(1), assistant(2)]
      {:ok, plan} = Planner.plan(agent(next: 3, boundary: -1), full, ctx())

      now = ~U[2026-01-01 00:00:00Z]

      assert [{:system, sys}, {:user, %User{parts: [%Part.Text{text: text}]}}] =
               Planner.new_messages(plan, "S", now)

      assert sys.index == plan.marker_index + 1
      assert sys.parts == [%Part.Text{text: plan.system_text}]
      assert text == "Summary of earlier conversation:\n\nS"
      assert Planner.orphan_from(plan) == 3
    end
  end

  describe "chunking and truncation" do
    test "splits an oversized conversation into multiple bounded chunks" do
      big = String.duplicate("x", 150_000)

      full = [
        system_msg(0),
        user(1, big),
        assistant(2),
        user(3, big),
        assistant(4),
        user(5, big),
        assistant(6)
      ]

      assert {:ok, plan} = Planner.plan(agent(next: 7, boundary: -1), full, ctx())

      assert length(plan.chunks) >= 2
      refute plan.truncated?

      for chunk <- plan.chunks do
        assert Estimator.estimate_messages(chunk) <= plan.chunk_budget + 10_000
      end
    end

    test "truncates a single message larger than the chunk budget" do
      big = String.duplicate("y", 2_000_000)
      full = [system_msg(0), user(1, big)]

      assert {:ok, plan} = Planner.plan(agent(next: 2, boundary: -1), full, ctx())

      assert plan.truncated?
      assert length(plan.chunks) == 1
      assert Estimator.estimate_messages(hd(plan.chunks)) <= plan.chunk_budget
    end

    test "never splits between a tool_use and its result" do
      big = String.duplicate("r", 2_000_000)
      full = [system_msg(0), assistant_tool(1, "call_1"), tool_result(2, "call_1", big)]

      assert {:ok, plan} = Planner.plan(agent(next: 3, boundary: -1), full, ctx())

      assert plan.truncated?
      assert length(plan.chunks) == 1

      assert [
               {:assistant, %Assistant{parts: [%Part.ToolUse{id: "call_1"}]}},
               {:tool, %Tool{parts: [%Part.ToolResult{tool_call_id: "call_1"}]}}
             ] =
               hd(plan.chunks)
    end

    test "enforces the summarization call cap" do
      big = String.duplicate("x", 250_000)
      full = [system_msg(0), user(1, big), assistant(2), user(3, big), assistant(4)]

      assert {:error, {:too_many_calls, _count, 1}} =
               Planner.plan(agent(next: 5, boundary: -1), full, ctx(%{max_calls: 1}))
    end
  end

  describe "system prompt headroom" do
    setup do
      %{agent: agent(next: 2, boundary: -1), full: [system_msg(0), user(1)]}
    end

    test "falls back to the vocation prompt when the rendered one is oversized",
         %{agent: agent, full: full} do
      huge = String.duplicate("z", 300_000)

      assert {:ok, plan} =
               Planner.plan(
                 agent,
                 full,
                 ctx(%{system_prompt: huge, fallback_system_prompt: "fb"})
               )

      assert plan.system_text == "fb"
    end

    test "reserve_exhausted when even the fallback leaves no summary headroom",
         %{agent: agent, full: full} do
      huge = String.duplicate("z", 300_000)

      assert {:error, :reserve_exhausted} =
               Planner.plan(
                 agent,
                 full,
                 ctx(%{system_prompt: huge, fallback_system_prompt: huge})
               )
    end
  end

  # ---- helpers ----

  defp agent(opts) do
    struct(PersistedAgent, %{
      id: Keyword.get(opts, :id, 1),
      name: "agent",
      space_id: 1,
      model: %{"name" => "m", "provider" => "p"},
      workspace_path: nil,
      vocation_id: 1,
      next_message_index: Keyword.get(opts, :next, 1),
      last_compaction_index: Keyword.get(opts, :boundary, -1),
      depth: 0
    })
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        agent_context_limit: 200_000,
        agent_context_limit_source: :config,
        summarizer_context_limit: 200_000,
        system_prompt: "system",
        fallback_system_prompt: "fallback",
        focus: nil,
        max_calls: 64
      },
      overrides
    )
  end

  defp system_msg(index, text \\ "sys") do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: text}], api_logs: []}}
  end

  defp user(index, text \\ "hello") do
    {:user, %User{index: index, parts: [%Part.Text{text: text}]}}
  end

  defp assistant(index, text \\ "ok") do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: text}], api_logs: []}}
  end

  defp assistant_tool(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}}],
       api_logs: []
     }}
  end

  defp tool_result(index, id, content) do
    {:tool,
     %Tool{
       index: index,
       parts: [
         %Part.ToolResult{tool_call_id: id, name: "shell-cmd", content: content, is_error: false}
       ],
       api_logs: []
     }}
  end

  defp index({_role, %{index: idx}}), do: idx
end
