defmodule MachineCompactionResumeDrainTest do
  @moduledoc false
  # The post-compaction segment and the inbox (issue #117): a queued message is
  # delivered onto a `{:compact_resume, …}` segment rather than waiting behind a
  # generated turn nobody asked for, in both of the shapes that entry reaches
  # the drain decision in. Behavior contract carried by the tests + inline `#`
  # comments, like the rest of the machine contract.
  #
  # Split out of `machine_boundary_delivery_test.exs`, which is at the credo
  # source-file cap; the fixtures here are the two lines that file's
  # `boundary_state/2` sets up for the same shape.

  use ExUnit.Case, async: true

  import Nest.TestSupport.MachineTestHelpers

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Boundary
  alias Nest.Agents.Agent.Machine.Compaction

  describe "a compact_resume segment and the inbox (issue #117)" do
    test "the success shape: the segment ends on the summary, and drains" do
      # intentional: with the compact call and its result archived, the
      # post-compaction segment ends on the summary — a `user` row, but not a
      # turn waiting for an answer: it is the seed of the new context. A queued
      # message is delivered onto it rather than waiting behind a generated turn
      # nobody asked for.
      machine = resume_segment()

      assert Boundary.drain?(machine)

      # The entry is what makes it drainable: the same user tail with no entry
      # dispatches instead. That is the property the entry clause exists for, and
      # it is invisible without this comparison.
      refute Boundary.drain?(%{machine | entry: nil})

      {:ok, actions, _next} = Machine.step(machine, :iterate)

      assert {:drain_inbox} in actions
      refute Enum.any?(actions, &match?({:spawn_http, _}, &1))
    end

    test "the failure shape: the segment still ends on the request, and drains" do
      # intentional: `compaction_failed/3`'s non-nil carried arm resumes the turn
      # with the `[mode: compact]` request row still at the tail, so the entry
      # clause's "ends on the summary" premise does not hold on this path — and
      # the disposition is the same on purpose. Before the `:compact_resume`
      # entry this shape carried the tool pair, whose `tool` tail drained too:
      # the queued message is the real work, and the failed compaction is
      # already broadcast (`:context_overflow` / `:compaction_failed`) and
      # visible in the transcript.
      staged = %{resume_segment() | entry: {:compaction, {:compact_resume, 0, 10}, nil}}

      {:ok, _actions, failed} =
        Compaction.compaction_failed(staged, :boom, {:compact_resume, 0, 10})

      assert failed.kind == :chat and failed.phase == :generating
      assert Boundary.drain?(failed)

      {:ok, actions, _next} = Machine.step(failed, :iterate)

      assert {:drain_inbox} in actions
      refute Enum.any?(actions, &match?({:spawn_http, _}, &1))
    end
  end

  # A `:generating` chat machine whose segment ends on a `user` row and whose
  # inbox holds one message: the post-compaction shape, where that row is the
  # summary (or, on the failure path, the compaction request).
  defp resume_segment do
    ctx =
      ctx()
      |> Map.put(:inbox_count, 1)
      |> Map.put(:messages, [{:user, user()}])

    %{state_at(:generating, ctx: ctx) | entry: {:compact_resume, 0, 10}}
  end
end
