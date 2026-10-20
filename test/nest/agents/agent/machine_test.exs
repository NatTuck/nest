defmodule MachineTest do
  @moduledoc false
  # NOTE: per the project rule, this file's behavior contract is carried by
  # the tests + inline # comments below, not by this moduledoc.

  use ExUnit.Case, async: true

  import Nest.TestSupport.MachineTestHelpers

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Compaction
  alias Nest.Messages.Part

  describe "vocabulary" do
    test "blocked phases are a subset of the declared phases" do
      # The subset is load-bearing: `MachineDebtTest` walks `phases() -- blocked`
      # and then `blocked`, so a blocked phase missing from `phases()` would
      # silently drop that phase's give-up and discharge sites.
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

    test "status_to_machine round-trips the observable status" do
      for status <- [:idle, :streaming, :executing_tools, :compacting] do
        assert Machine.status_for(Machine.status_to_machine(%Machine{}, status)) == status
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
            Machine.validate!(next)

            # Every emitted action must be in the declared vocabulary (and
            # therefore have an executor clause). Guards against a
            # transition emitting an action the executor cannot run.
            for action <- actions do
              assert action_tag(action) in Machine.actions(),
                     "#{inspect(tag)}/#{inspect(phase)} emitted undeclared action #{inspect(action)}"
            end

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
    test "a chat request appends the user message and defers an :iterate" do
      idle = state_at(:idle)

      {:ok, actions, generating} = Machine.step(idle, {:chat_request, {:user_message, user()}})

      # intentional: the user message append and the worker spawn are
      # separated by a mailbox `:iterate`, preserving the old driver's
      # async boundary.
      assert Enum.any?(actions, &match?({:append, _}, &1))
      assert :iterate in actions
      assert generating.phase == :generating and generating.kind == :chat
    end

    test "a late worker result after :stopping is dropped, not appended" do
      # intentional: once a stop is in flight the terminal recovery closes
      # the sequence. A late HTTP/tool result MUST be dropped; appending it
      # would orphan the result. Do not "repair" this by appending.
      # The `:tool_results` arm of the same guard is covered by
      # `MachineBackgroundedTest`, where the guard must also win over the
      # backgrounded clauses.
      stopping =
        Machine.new(phase: :stopping, kind: :chat, work: %Machine.Work{worker_ref: make_ref()})

      assert {:ignore, :late_result_after_stop, ^stopping} =
               Machine.step(stopping, {:http_ok, make_ref(), response()})
    end

    test "a stale result in :idle is a no-op" do
      # intentional: a duplicate/very-late result with nothing waiting is
      # ignored, not an error and not an append.
      idle = Machine.new()

      assert {:ignore, :stale_result, ^idle} =
               Machine.step(idle, {:http_ok, make_ref(), response()})

      assert {:ignore, :stale_result, ^idle} = Machine.step(idle, {:tool_results, make_ref(), []})
    end

    test "a mid-turn compaction request switches the turn kind, not an unrelated phase" do
      # intentional: compaction is modeled as (kind: :compaction,
      # phase: :generating), so its observable status is :compacting while
      # the physical HTTP worker is in flight.
      generating = state_at(:generating)

      {:ok, actions, next} = Compaction.stage(generating, {:tool_call, %{}, 1, 10})

      assert next.kind == :compaction and next.phase == :generating
      assert :iterate in actions
      Machine.validate!(next)
    end

    test "stop keeps the worker ref for signaling but clears the worker kind" do
      # intentional: the executor needs the pid to signal the in-flight
      # task; the phase is no longer "waiting on that kind", so the kind is
      # cleared and the invariant holds.
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      generating =
        Machine.new(
          phase: :generating,
          kind: :chat,
          work: %Machine.Work{worker_kind: :http, worker_ref: make_ref(), active_worker: pid}
        )

      {:ok, actions, stopping} = Machine.step(generating, {:stop, self()})

      assert stopping.phase == :stopping
      assert stopping.work.worker_kind == nil
      assert Enum.any?(actions, &match?({:kill, ^pid}, &1))
      assert Enum.any?(actions, &match?({:arm_timer, _, :stop_timer}, &1))

      Process.exit(pid, :kill)
    end

    test "a stop kills the batch coordinators the machine is reporting to" do
      # A batch coordinator is an unlinked task, so killing only the turn's own
      # worker would leave it spawning children and later delivering an
      # aggregate into a parent that asked to stop. Every distinct reporting
      # target is killed, once each, in name order.
      coordinator =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      other =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      machine =
        Enum.reduce(
          [{"alpha", coordinator}, {"beta", coordinator}, {"gamma", other}, {"delta", nil}],
          Machine.new(phase: :generating),
          fn {name, target}, m ->
            {:ok, [], m} = Machine.step(m, {:child_spawned, name, false, target})
            m
          end
        )

      {:ok, actions, _stopping} = Machine.step(machine, {:stop, self()})

      assert Enum.filter(actions, &match?({:kill, _}, &1)) ==
               [{:kill, coordinator}, {:kill, other}]

      Process.exit(coordinator, :kill)
      Process.exit(other, :kill)
    end

    test "blocked phases ignore ordinary work" do
      blocked = Machine.new(phase: :needs_repair)

      assert {:ignore, :blocked, ^blocked} =
               Machine.step(blocked, {:chat_request, {:user_message, user()}})
    end

    test "the committing phase is a compaction-only phase reported as :compacting" do
      # intentional: `:committing` exists so a compaction commit has a
      # distinct phase; it is only ever `kind: :compaction`.
      committing = %Machine{kind: :compaction, phase: :committing}

      assert Machine.status_for(committing) == :compacting
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
        Machine.validate!(Machine.new(phase: :generating, kind: :chat))
      end
    end

    test "validate!/1 rejects :executing_tools for a compaction kind" do
      assert_raise RuntimeError, ~r/chat-only/, fn ->
        Machine.validate!(
          Machine.new(
            phase: :executing_tools,
            kind: :compaction,
            work: %Machine.Work{worker_kind: :tools}
          )
        )
      end
    end

    test "validate!/1 rejects a worker kind in idle" do
      assert_raise RuntimeError, ~r/must not have a worker_kind/, fn ->
        Machine.validate!(Machine.new(phase: :idle, work: %Machine.Work{worker_kind: :http}))
      end
    end

    test "validate!/1 rejects :committing for a chat kind" do
      assert_raise RuntimeError, ~r/compaction-only/, fn ->
        Machine.validate!(Machine.new(phase: :committing, kind: :chat))
      end
    end
  end

  describe "property: random event sequences preserve invariants" do
    test "no declared event ever quarantines and the machine stays valid" do
      :rand.seed(:exsss, {1, 2, 3})
      tags = Machine.events()

      Enum.reduce(1..500, state_at(:idle), fn _, state ->
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

  describe "outgoing wire validation" do
    test ":iterate validates the outgoing tail: a trailing assistant fails, a tool result ships" do
      # Regression: an outgoing request must never end on an assistant
      # role. `Preflight.validate_request/1` catches it and fails the turn
      # with a visible error rather than letting the provider 400.
      base = state_at(:generating)
      ack = {:assistant, %Nest.Messages.Assistant{parts: [%Nest.Messages.Part.Text{text: "ack"}]}}
      ctx = %{base.work.ctx | messages: base.work.ctx.messages ++ [{:user, user()}, ack]}
      m = %{base | work: %{base.work | ctx: ctx}}

      {:ok, actions, next} = Machine.step(m, :iterate)

      assert Enum.any?(actions, &match?({:fail_turn, %ArgumentError{}, []}, &1))
      refute Enum.any?(actions, &match?({:spawn_http, _}, &1))
      assert next.phase == :idle

      tool = %Nest.Messages.Tool{
        parts: [
          %Nest.Messages.Part.ToolResult{
            tool_call_id: "c1",
            name: "shell-cmd",
            content: "ok",
            is_error: false
          }
        ]
      }

      calls = [
        %Nest.Messages.Part.ToolUse{id: "c1", name: "shell-cmd", arguments: %{}},
        %Part.Text{text: "working"}
      ]

      assistant = {:assistant, %Nest.Messages.Assistant{parts: calls}}

      ctx = %{
        base.work.ctx
        | messages: base.work.ctx.messages ++ [{:user, user()}, assistant, {:tool, tool}]
      }

      m = %{base | work: %{base.work | ctx: ctx}}

      {:ok, actions, _next} = Machine.step(m, :iterate)

      assert Enum.any?(actions, &match?({:spawn_http, _}, &1))
    end
  end
end
