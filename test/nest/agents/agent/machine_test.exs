defmodule Nest.Agents.Agent.MachineTest do
  @moduledoc false
  # NOTE: per the project rule, this file's behavior contract is carried by
  # the tests + inline # comments below, not by this moduledoc.

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine

  describe "vocabulary" do
    test "phases and events are declared and blocked is a subset of phases" do
      refute Enum.empty?(Machine.phases())
      refute Enum.empty?(Machine.events())
      assert MapSet.subset?(MapSet.new(Machine.blocked_phases()), MapSet.new(Machine.phases()))
    end
  end

  describe "status_for/1 is total and derived" do
    test "every declared phase has a status" do
      for phase <- Machine.phases() do
        status = Machine.status_for(Machine.new(phase: phase, kind: kind_for(phase)))
        assert is_atom(status) and status != nil
      end
    end

    test "kind is not collapsed into phase" do
      # intentional: a compaction in flight is status :compacting via
      # (kind: :compaction, phase: :generating); it is not reported as
      # :streaming just because the physical worker is an HTTP worker.
      assert Machine.status_for(Machine.new(kind: :compaction, phase: :generating)) == :compacting

      assert Machine.status_for(Machine.new(kind: :chat, phase: :generating)) == :streaming
    end

    test "blocked phases report themselves" do
      for phase <- Machine.blocked_phases() do
        assert Machine.status_for(Machine.new(phase: phase)) == phase
      end
    end
  end

  describe "transition coverage" do
    test "every (phase, declared event) classifies and yields a valid state" do
      for phase <- Machine.phases(), tag <- Machine.events() do
        state = state_at(phase)
        event = sample_event(tag)

        result = Machine.step(state, event)

        assert result != :quarantine,
               "declared event #{inspect(tag)} quarantined in #{inspect(phase)}"

        case result do
          {:ok, actions, next} ->
            assert is_list(actions)
            Machine.validate!(next)

          {:ignore, reason, next} ->
            assert is_atom(reason)
            Machine.validate!(next)
        end
      end
    end
  end

  describe "quarantine" do
    test "an undeclared event tag quarantines" do
      assert Machine.step(Machine.new(), {:not_a_real_event, %{}}) == :quarantine
      assert Machine.step(Machine.new(), :also_not_real) == :quarantine
    end
  end

  describe "intentional behaviors" do
    test "chat turn alternates generating and executing_tools" do
      idle = Machine.new()

      {:ok, _actions, generating} = Machine.step(idle, {:chat_request, %{text: "hi"}})
      assert generating.phase == :generating and generating.kind == :chat
      Machine.validate!(generating)

      {:ok, _actions, tools} =
        Machine.step(generating, {:http_ok, %{tool_calls: [%{id: "c1"}]}})

      assert tools.phase == :executing_tools
      Machine.validate!(tools)

      {:ok, _actions, back} = Machine.step(tools, {:tool_results, %{results: []}})
      assert back.phase == :generating
      Machine.validate!(back)
    end

    test "a late worker result after :stopping is dropped, not appended" do
      # intentional: once a stop is in flight the terminal recovery closes
      # the sequence. A late HTTP/tool result MUST be dropped; appending it
      # would orphan the result. Do not "repair" this by appending.
      stopping = %{Machine.new(phase: :stopping, kind: :chat) | worker_ref: make_ref()}

      assert {:ignore, :late_result_after_stop, ^stopping} =
               Machine.step(stopping, {:http_ok, %{tool_calls: []}})

      assert {:ignore, :late_result_after_stop, ^stopping} =
               Machine.step(stopping, {:tool_results, %{results: []}})
    end

    test "a stale result in :idle is a no-op" do
      # intentional: a duplicate/very-late result with nothing waiting is
      # ignored, not an error and not an append.
      idle = Machine.new()

      assert {:ignore, :stale_result, ^idle} = Machine.step(idle, {:http_ok, %{tool_calls: []}})
      assert {:ignore, :stale_result, ^idle} = Machine.step(idle, {:tool_results, %{}})
    end

    test "a mid-turn compaction request switches the turn kind, not an unrelated phase" do
      # intentional: compaction is modeled as (kind: :compaction,
      # phase: :generating), so its observable status is :compacting while
      # the physical HTTP worker is in flight. Kind is never folded into
      # phase.
      generating = %{Machine.new(phase: :generating, kind: :chat) | worker_kind: :http}

      {:ok, actions, next} =
        Machine.step(generating, {:compaction_request, {:tool_call, %{}, 1, 10}})

      assert next.kind == :compaction and next.phase == :generating
      assert next.resume == {:tool_call, %{}, 1, 10}
      assert Enum.any?(actions, &match?({:stage_compaction, _}, &1))
      Machine.validate!(next)
    end

    test "stop keeps the worker ref for signaling but clears the worker kind" do
      # intentional: the executor needs the ref to signal the in-flight
      # task; the phase is no longer "waiting on that kind", so the kind is
      # cleared and the invariant holds.
      ref = make_ref()

      generating = %{
        Machine.new(phase: :generating, kind: :chat)
        | worker_kind: :http,
          worker_ref: ref
      }

      {:ok, actions, stopping} = Machine.step(generating, {:stop, self()})

      assert stopping.phase == :stopping
      assert stopping.worker_kind == nil
      assert Enum.any?(actions, &match?({:kill, ^ref}, &1))
      assert Enum.any?(actions, &match?({:arm_timer, _}, &1))
      Machine.validate!(stopping)
    end

    test "blocked phases ignore ordinary work" do
      blocked = Machine.new(phase: :needs_repair)

      assert {:ignore, :blocked, ^blocked} = Machine.step(blocked, {:chat_request, %{}})
      assert {:ignore, :blocked, ^blocked} = Machine.step(blocked, {:stop, self()})
    end
  end

  describe "invariants" do
    test "validate!/1 accepts every declared phase" do
      for phase <- Machine.phases() do
        Machine.validate!(state_at(phase))
      end
    end

    test "validate!/1 rejects a generating phase with no worker kind" do
      assert_raise RuntimeError, ~r/worker_kind/, fn ->
        Machine.validate!(Machine.new(phase: :generating, kind: :chat, worker_kind: nil))
      end
    end

    test "validate!/1 rejects :executing_tools for a compaction kind" do
      assert_raise RuntimeError, ~r/chat-only/, fn ->
        Machine.validate!(
          Machine.new(phase: :executing_tools, kind: :compaction, worker_kind: :tools)
        )
      end
    end

    test "validate!/1 rejects a worker kind in idle" do
      assert_raise RuntimeError, ~r/must not have a worker_kind/, fn ->
        Machine.validate!(Machine.new(phase: :idle, worker_kind: :http))
      end
    end
  end

  describe "property: random event sequences preserve invariants" do
    test "no declared event ever quarantines and the machine stays valid" do
      :rand.seed(:exsss, {1, 2, 3})
      tags = Machine.events()

      Enum.reduce(1..500, Machine.new(), fn _, state ->
        tag = Enum.at(tags, :rand.uniform(length(tags)) - 1)
        result = Machine.step(state, sample_event(tag))

        assert result != :quarantine

        next =
          case result do
            {:ok, _actions, next} -> next
            {:ignore, _reason, next} -> next
          end

        Machine.validate!(next)
        assert is_atom(Machine.status_for(next))
        next
      end)
    end
  end

  # --- helpers ---

  defp kind_for(:committing), do: :compaction
  defp kind_for(_), do: :chat

  defp state_at(phase) do
    Machine.new(
      phase: phase,
      kind: kind_for(phase),
      worker_kind: worker_kind_for(phase),
      worker_ref: ref_for(phase)
    )
  end

  defp worker_kind_for(:generating), do: :http
  defp worker_kind_for(:executing_tools), do: :tools
  defp worker_kind_for(_), do: nil

  defp ref_for(p) when p in [:generating, :executing_tools, :stopping], do: make_ref()
  defp ref_for(_), do: nil

  defp sample_event(:chat_request), do: {:chat_request, %{text: "hi"}}
  defp sample_event(:http_ok), do: {:http_ok, %{tool_calls: []}}
  defp sample_event(:http_error), do: {:http_error, :boom}
  defp sample_event(:worker_crashed), do: {:worker_crashed, %RuntimeError{}, []}
  defp sample_event(:worker_down), do: {:worker_down, :killed}
  defp sample_event(:tool_results), do: {:tool_results, %{results: []}}
  defp sample_event(:stop), do: {:stop, self()}
  defp sample_event(:stop_timer), do: :stop_timer
  defp sample_event(:compaction_request), do: {:compaction_request, {:tool_call, %{}, 1, 10}}
  defp sample_event(:compaction_ok), do: {:compaction_ok, %{summary: "s"}}
  defp sample_event(:compaction_error), do: {:compaction_error, :boom}
  defp sample_event(:child_completed), do: {:child_completed, "kid", "resp", %{}}
  defp sample_event(:child_failed), do: {:child_failed, "kid", :crashed}
  defp sample_event(:child_terminated), do: {:child_terminated, "kid", :killed}
  defp sample_event(:abandon_child), do: {:abandon_child, "kid"}
  defp sample_event(:inbox_drain), do: {:inbox_drain, %{text: "queued"}}
  defp sample_event(:retry_compaction), do: :retry_compaction
  defp sample_event(:loop_ack), do: :loop_ack
end
