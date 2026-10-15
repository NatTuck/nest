defmodule MachineCompactionRequestTest do
  @moduledoc false
  # NOTE: per the project rule, this file's behavior contract is carried by
  # the tests + inline # comments below, not by this moduledoc.

  use ExUnit.Case, async: true

  import Nest.TestSupport.MachineTestHelpers

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Response
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall

  describe "manual compaction (:compact_request)" do
    test "from :idle it stages a compaction turn and defers an :iterate" do
      # intentional: /compact reuses the exact automatic-compaction path;
      # the only difference is the user-initiated entry point.
      {:ok, actions, next} = Machine.step(state_at(:idle), {:compact_request, nil})

      assert :iterate in actions
      assert next.kind == :compaction and next.phase == :generating
      assert {:compaction, nil} = next.entry

      # The request is appended before the compactor runs.
      assert Enum.any?(actions, &match?({:append, {:user, _}}, &1))

      Machine.validate!(next)
    end

    test "threads the focus onto work and into the compaction request message" do
      # intentional: `/compact <focus>` carries the operator's guidance
      # onto `work.focus`; `Dispatch.compaction_plan/1` renders it into the
      # `[mode: compact]` request message, which the machine then appends.
      {:ok, actions, next} =
        Machine.step(state_at(:idle), {:compact_request, "keep the API decisions"})

      assert next.work.focus == "keep the API decisions"
      assert {:compaction, nil} = next.entry

      # The focus rides in the request message's own text, which is why
      # `/compact <focus>` needs no row of its own in the transcript.
      assert {:append, {:user, %{parts: [%Part.Text{text: text}]}}} =
               Enum.find(actions, &match?({:append, _}, &1))

      assert text =~ "keep the API decisions"
    end

    test "renders no guidance when the focus is nil" do
      # intentional: a bare `/compact` (nil focus) renders the plain
      # budget suffix with no trailing guidance.
      {:ok, request_message} = Dispatch.compaction_plan(state_at(:idle))

      assert {:user, %{parts: [%Part.Text{text: text}]}} = request_message
      refute text =~ "keep the API decisions"
      assert text =~ "remaining tokens"
    end

    test "from a non-idle phase it is ignored" do
      # intentional: compaction only starts from idle; a request while a
      # turn is in flight is a no-op (the Agent rejects it before stepping).
      generating = state_at(:generating)

      assert {:ignore, :not_applicable, ^generating} =
               Machine.step(generating, {:compact_request, nil})
    end

    test "a fourth consecutive manual request never trips the loop breaker" do
      # intentional: a manual request resets loop_count before staging, so
      # deliberate back-to-back compactions are not mistaken for the
      # automatic compaction loop the breaker guards against. Four is one
      # more than the cap, so this only passes because of the reset: without
      # it the fourth request would trip `:compaction_loop_detected`.
      {tripped?, final} =
        Enum.reduce(1..4, {false, state_at(:idle)}, fn _, {tripped?, machine} ->
          {:ok, actions, next} = Machine.step(machine, {:compact_request, nil})

          tripped =
            tripped? or
              Enum.any?(actions, &match?({:broadcast, {:compaction_loop, _, _, _}, _}, &1))

          # Simulate the compaction completing and returning to idle,
          # carrying the loop_count the stage left behind.
          {tripped, %{next | phase: :idle, kind: :chat, work: %{next.work | worker_kind: nil}}}
        end)

      refute tripped?
      assert final.loop_count == 1
    end
  end

  describe "context-compact tool focus" do
    test "the tool call's focus rides onto work and into the request message" do
      # intentional: the LLM's optional `context-compact` `focus` arg is
      # threaded the same way `/compact <focus>` is — onto `work.focus`, which
      # `Dispatch.compaction_plan/1` renders into the request message the
      # machine appends. An empty arguments map leaves the focus nil, so the
      # plain budget request is rendered with no guidance.
      cases = [
        {%{"focus" => "keep the API decisions"}, "keep the API decisions", true},
        {%{}, nil, false}
      ]

      for {arguments, expected_focus, guided?} <- cases do
        call = %ToolCall{id: "c1", name: "context-compact", arguments: arguments}

        {:ok, actions, next} =
          Response.dispatch(state_at(:generating), response(tool_calls: [call]))

        assert next.work.focus == expected_focus
        assert {:compaction, {:compact_tool, _, 0, 10}} = next.entry

        assert {:append, {:user, _} = request} = Enum.find(actions, &match?({:append, _}, &1))
        assert inspect(request) =~ "keep the API decisions" == guided?
      end
    end
  end

  describe "turn-scoped focus lifetime" do
    test "the focus does not survive the compaction turn into a later automatic compaction" do
      {:ok, _actions, staged} =
        Machine.step(state_at(:idle), {:compact_request, "keep the API decisions"})

      # intentional: while the compaction turn is staged the operator's
      # guidance is threaded onto `work.focus` and rendered into the
      # suffix — this is the sanity check that it IS carried.
      assert staged.work.focus == "keep the API decisions"

      {:ok, _actions, resumed} = Machine.step(%{staged | phase: :committing}, {:commit_done})

      # intentional: finishing the compaction turn ends it (chat/idle), and
      # that turn boundary drops the focus. A stale focus that survived
      # would be silently applied to the NEXT *automatic* compaction
      # (staged from `start_chat/3`'s `:needs_compaction`,
      # `finalize_or_defer/4`, or `:workspace_notice`) — a summary nobody
      # asked for.
      assert resumed.phase == :idle
      assert resumed.work.focus == nil

      # intentional: the observable consequence of the reset — the next
      # compaction plan renders the plain budget suffix, with no stale
      # operator guidance in it.
      assert {:ok, request_message} = Dispatch.compaction_plan(resumed)
      assert {:user, %{parts: [%Part.Text{text: text}]}} = request_message
      refute text =~ "keep the API decisions"
      assert text =~ "remaining tokens"
    end

    test "a retry after a compaction failure re-renders the same focus" do
      {:ok, _actions, staged} =
        Machine.step(state_at(:idle), {:compact_request, "keep the API decisions"})

      {:ok, _actions, failed} = Machine.Compaction.compaction_failed(staged, :boom, nil)

      # intentional: `:compaction_failed` is entered via `enter_blocked/2`,
      # which must KEEP the focus — the failed turn is retryable and the
      # retry is the same compaction turn.
      assert failed.phase == :compaction_failed
      assert failed.work.focus == "keep the API decisions"

      {:ok, actions, retried} = Machine.step(failed, :retry_compaction)

      # intentional: a retry re-sends the existing sequence — it does not
      # re-plan, so it appends nothing and `work.focus` survives.
      assert retried.kind == :compaction and retried.phase == :generating
      assert retried.work.focus == "keep the API decisions"
      assert {:compaction, nil} = retried.entry
      refute Enum.any?(actions, &match?({:append, _}, &1))
      assert :iterate in actions
    end
  end
end
