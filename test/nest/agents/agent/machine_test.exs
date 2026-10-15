defmodule MachineTest do
  @moduledoc false
  # NOTE: per the project rule, this file's behavior contract is carried by
  # the tests + inline # comments below, not by this moduledoc.

  use ExUnit.Case, async: true

  import Nest.TestSupport.MachineTestHelpers

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Compaction
  alias Nest.Agents.Agent.Machine.Response
  alias Nest.Agents.Agent.Machine.Turn
  alias Nest.Agents.Agent.Repair
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall

  describe "vocabulary" do
    test "phases, events, actions are declared and blocked is a subset of phases" do
      refute Enum.empty?(Machine.phases())
      refute Enum.empty?(Machine.events())
      refute Enum.empty?(Machine.actions())
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
            assert is_list(actions)
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
      Machine.validate!(generating)
    end

    test "a late worker result after :stopping is dropped, not appended" do
      # intentional: once a stop is in flight the terminal recovery closes
      # the sequence. A late HTTP/tool result MUST be dropped; appending it
      # would orphan the result. Do not "repair" this by appending.
      stopping =
        Machine.new(phase: :stopping, kind: :chat, work: %Machine.Work{worker_ref: make_ref()})

      assert {:ignore, :late_result_after_stop, ^stopping} =
               Machine.step(stopping, {:http_ok, make_ref(), response()})

      assert {:ignore, :late_result_after_stop, ^stopping} =
               Machine.step(stopping, {:tool_results, make_ref(), []})
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

      {:ok, actions, next} = Compaction.stage(generating, {:tool_call, %{}, 1, 10}, nil)

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
      Machine.validate!(stopping)

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

      assert {:ignore, :blocked, ^blocked} = Machine.step(blocked, :iterate)
    end

    test "the committing phase is a compaction-only phase reported as :compacting" do
      # intentional: `:committing` exists so a compaction commit has a
      # distinct phase; it is only ever `kind: :compaction`.
      committing = %Machine{kind: :compaction, phase: :committing}

      assert Machine.status_for(committing) == :compacting
      Machine.validate!(committing)
    end
  end

  describe "compaction decisions" do
    test "the loop-breaker blocks after the consecutive cap" do
      m = %{state_at(:idle) | loop_count: 3, entry: {:compaction, nil}}
      {:ok, actions, next} = Machine.Compaction.stage(m, nil, nil)

      assert next.phase == :compaction_loop_detected
      assert Enum.any?(actions, &match?({:broadcast, {:compaction_loop, _, _, _}, _}, &1))
    end

    test "a deferred assistant reply stays blocked on compaction failure" do
      m = state_at(:idle)
      reply = {:assistant_response, user(), 1, 5}
      {:ok, actions, next} = Machine.Compaction.compaction_failed(m, :boom, reply)

      assert next.phase == :compaction_failed
      assert Enum.any?(actions, &match?({:broadcast, {:compaction_error, _}, _}, &1))
    end

    test "resume emits the deferred workspace notice pair" do
      base = state_at(:idle)
      m = %{base | entry: {:compaction, nil}, work: %{base.work | pending_notice: "/tmp/x"}}
      {:ok, actions, next} = Machine.Compaction.resume(m)

      assert next.phase == :idle
      assert Enum.any?(actions, &match?({:append_many, _}, &1))
    end

    # BLOCKER, found by the PR #101 review. A refused batch is the
    # near-the-limit case compaction exists for, and `Response.regular/5` has
    # already appended the assistant carrying that batch's `tool_use` parts.
    # `Repair.classify_live/2` refuses a `user` append while any are pending,
    # so the compaction request could not be committed — and because a refused
    # append is a `{:follow, …}` that halts the action list, the phase's
    # default clause swallowed it and the agent sat in `:compacting` with no
    # worker, no timer and no exit but stop/archive/restart.
    test "a refused batch answers its tool tail before staging, so the request can be committed" do
      ctx = %{ctx() | messages: [system_message(), assistant_with_tool_use()]}
      # `preflight` is set by `Response.regular/5` before the refusal arrives;
      # the clause reads `continuation` off it. A nil preflight is
      # `{:ignore, :no_preflight}`.
      m = state_at(:generating, ctx: ctx, preflight: %{calls: [], continuation: nil})

      {:ok, actions, next} = Machine.step(m, {:preflight_result, {:refuse, :too_big}})

      # The heal comes FIRST, and it is a real append action — not a promise.
      assert [{:append_many, [heal]} | _] = actions
      assert {:tool, %{parts: [%Part.ToolResult{tool_call_id: "call_1", is_error: true}]}} = heal

      # intentional: the heal answers the tail, so the request append that
      # follows is legal — it gets the compaction bridge rather than the
      # `{:invalid, …}` refusal that wedged the machine.
      assert {:repair, [bridge]} =
               Repair.decide(:live, ctx.messages ++ [heal], {:user, compaction_request()})

      assert {:assistant, %{parts: [%Part.Text{text: "Let me pause to summarize."}]}} = bridge

      assert next.kind == :compaction and next.phase == :generating
      assert Enum.any?(actions, &match?({:append, _}, &1))
    end

    # The backstop for the same blocker: if the request append IS refused for
    # some reason nobody foresaw, it must be a visible turn failure rather
    # than the silent hang the default clause produced.
    test "a refused compaction-request append fails the turn instead of wedging" do
      m = state_at(:generating, kind: :compaction)

      {:ok, actions, next} = Machine.step(m, {:append_result, :invalid, "boom"})

      assert Enum.any?(actions, &match?({:fail_turn, %ArgumentError{message: "boom"}, _}, &1))
      assert next.phase == :idle
      assert next.entry == nil

      # intentional: NOT `:compaction_failed`. A retry re-sends the committed
      # sequence, and this sequence has no request row in it — the compactor
      # would be asked to summarize with no instruction.
      refute next.phase == :compaction_failed
    end

    # BLOCKER, found by the same review. `entry` is turn-scoped for a
    # compaction, and leaving one behind is not cosmetic:
    # `Response.dispatch/2` sets `compactor? = match?({:compaction, _}, m.entry)`
    # and `Machine.Turn.classify_response/1` checks that FIRST and
    # unconditionally — so the next chat turn's reply would be classified
    # `:compaction`, and `commit_compaction/2` would archive the whole active
    # segment and persist that reply as the summary.
    test "a compaction entry does not survive into the next chat turn" do
      failed = %{state_at(:compaction_failed, kind: :compaction) | entry: {:compaction, nil}}
      {:ok, _actions, looped} = Machine.step(%{failed | loop_count: 3}, :retry_compaction)

      assert looped.phase == :compaction_loop_detected
      # intentional: the entry SURVIVES here. `:compaction_loop_detected` is
      # the phase entered through `enter_blocked/2`, which deliberately skips
      # the turn-scoping that clears it — so a `:compaction_failed` retry can
      # still find it. (Note `Compaction.retry/1` itself reads
      # `mid_turn_entry`, not `entry`; the entry is kept here for the retry
      # path's own reasons, not because retry reads this field.)
      assert looped.entry == {:compaction, nil}

      {:ok, _actions, acked} = Machine.step(looped, :loop_ack)

      # intentional: `:loop_ack` gives up on the compaction, so the entry goes
      # with it. This is the assertion that was missing.
      assert acked.phase == :idle
      assert acked.entry == nil

      # intentional: the observable consequence — the reply to the operator's
      # next message is a CHAT reply, not a compaction summary.
      assert classify(acked.entry) == :finalize
      refute classify(acked.entry) == :compaction
    end

    test "a compaction entry does not survive an unblock either" do
      m = %{state_at(:needs_repair, kind: :compaction) | entry: {:compaction, nil}}

      {:ok, _actions, unblocked} = Machine.step(m, {:unblocked})

      assert unblocked.phase == :idle
      assert unblocked.entry == nil
      assert classify(unblocked.entry) == :finalize
    end
  end

  # `Machine.Turn.classify_response/1`'s full option set, with only
  # `compactor?` varying — so the assertion isolates the entry's effect.
  defp classify(entry) do
    Turn.classify_response(%{
      compactor?: match?({:compaction, _}, entry),
      force_finalize: false,
      has_tool_calls: false,
      iteration: 0,
      max_iterations: 10,
      empty_assistant?: false,
      truncated?: false,
      silent?: false
    })
  end

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

  describe "final-reply reserve deferral" do
    test "a reply that leaves the reserve intact is appended and finalizes" do
      m = %{state_at(:generating) | work: %{state_at(:generating).work | active_message_index: 1}}
      reply = response(text: "done", usage: %{input_tokens: 1_000, output_tokens: 10})

      {:ok, actions, next} = Response.dispatch(m, reply)

      # intentional: the reply fits (size + C <= L), so it is persisted
      # active-side immediately.
      assert Enum.any?(actions, &match?({:append, {:assistant, _}}, &1))
      assert {:finalize, :clean} in actions
      assert next.kind == :chat and next.phase == :idle
    end

    test "a reply that would spend the reserve is carried across a compaction" do
      m = %{state_at(:generating) | work: %{state_at(:generating).work | active_message_index: 1}}
      # 85k input + the 20k reserve exceeds the 100k context, so persisting
      # the reply would leave nothing free for the compaction request.
      reply = response(text: "done", usage: %{input_tokens: 85_000, output_tokens: 10})

      {:ok, actions, next} = Response.dispatch(m, reply)

      # intentional: defer the reply (do not persist it here); it is
      # committed active-side after the summary by `Compaction.resume/1`.
      refute Enum.any?(actions, &match?({:append, {:assistant, _}}, &1))
      assert :iterate in actions
      assert next.kind == :compaction and next.phase == :generating

      assert {:compaction, {:assistant_response, {:assistant, _}, 0, 10}} = next.entry
    end
  end

  describe "compaction resume" do
    test "a deferred assistant_response resume finalizes cleanly instead of casting to the parent" do
      # intentional: an idle-after-compaction resume must not emit a
      # malformed parent notification. The old `{:notify_parent, :completed}`
      # cast a bare `:completed` atom, which no parent `handle_cast/2`
      # clause matches (a child's parent would crash). It now finalizes
      # like any clean idle (the executor builds the real payload).
      carried = {:assistant_response, %Nest.Messages.Assistant{parts: []}, 0, 5}

      machine =
        Machine.new(
          phase: :committing,
          kind: :compaction,
          entry: {:compaction, carried}
        )

      {:ok, actions, next} = Machine.step(machine, {:commit_done})

      assert {:finalize, :clean} in actions
      refute Enum.any?(actions, &match?({:notify_parent, _}, &1))
      assert next.phase == :idle
    end
  end

  describe "outgoing wire validation" do
    test ":iterate with a trailing assistant fails the turn instead of shipping it" do
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
    end

    test ":iterate with a valid tool-result tail still spawns the request" do
      base = state_at(:generating)

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
