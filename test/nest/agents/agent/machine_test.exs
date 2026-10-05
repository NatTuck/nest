defmodule MachineTest do
  @moduledoc false
  # NOTE: per the project rule, this file's behavior contract is carried by
  # the tests + inline # comments below, not by this moduledoc.

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine

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

      {:ok, actions, next} =
        Machine.step(generating, {:compaction_request, {:tool_call, %{}, 1, 10}})

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
      m = %{state_at(:idle) | loop_count: 3, entry: {:compaction, [], nil}}
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
      m = %{base | entry: {:compaction, [], nil}, work: %{base.work | pending_notice: "/tmp/x"}}
      {:ok, actions, next} = Machine.Compaction.resume(m)

      assert next.phase == :idle
      assert Enum.any?(actions, &match?({:append_many, _}, &1))
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
          entry: {:compaction, [], carried}
        )

      {:ok, actions, next} = Machine.step(machine, {:commit_done})

      assert {:finalize, :clean} in actions
      refute Enum.any?(actions, &match?({:notify_parent, _}, &1))
      assert next.phase == :idle
    end
  end

  # --- helpers ---

  defp action_tag(:iterate), do: :iterate
  defp action_tag({tag}), do: tag
  defp action_tag({tag, _}), do: tag
  defp action_tag({tag, _, _}), do: tag
  defp action_tag({tag, _, _, _}), do: tag

  defp kind_for(:committing), do: :compaction
  defp kind_for(_), do: :chat

  defp user do
    %Nest.Messages.User{index: nil, parts: [%Nest.Messages.Part.Text{text: "hi"}], api_logs: []}
  end

  defp response(overrides \\ []) do
    struct(
      %Nest.LLM.RunResponse{
        text: "",
        thinking: nil,
        tool_calls: [],
        refusal: nil,
        stop_reason: :end_turn,
        model: "m",
        usage: %{}
      },
      overrides
    )
  end

  defp system_message do
    {:system,
     %Nest.Messages.System{
       index: 0,
       parts: [%Nest.Messages.Part.Text{text: "sys"}],
       api_logs: []
     }}
  end

  defp ctx do
    %{
      agent_pid: self(),
      agent_name: "a",
      space_id: 1,
      client_config: %Nest.LLM.ClientConfig{client: Nest.LLM.MockClient, model: "m"},
      tools: [],
      tool_choice: :auto,
      caps: %{},
      context_limit: 100_000,
      context_limit_source: :default,
      messages: [system_message()],
      tmp_path: nil,
      workspace_path: nil,
      mode: "chat",
      next_message_index: 1,
      crossed_thresholds: %MapSet{},
      context_projection: nil,
      api_log_sequences: %{},
      vocation: nil,
      depth: 0
    }
  end

  defp state_at(phase) do
    Machine.new(
      phase: phase,
      kind: kind_for(phase),
      work: %Machine.Work{
        worker_kind: worker_kind_for(phase),
        worker_ref: ref_for(phase),
        ctx: ctx(),
        max_iterations: 10
      }
    )
  end

  defp worker_kind_for(:generating), do: :http
  defp worker_kind_for(:executing_tools), do: :tools
  defp worker_kind_for(_), do: nil

  defp ref_for(p) when p in [:generating, :executing_tools, :stopping], do: make_ref()
  defp ref_for(_), do: nil

  defp sample_event(:chat_request), do: {:chat_request, {:user_message, user()}}
  defp sample_event(:iterate), do: :iterate
  defp sample_event(:inbox_drain), do: {:inbox_drain, [], "queued"}
  defp sample_event(:http_ok), do: {:http_ok, make_ref(), response()}
  defp sample_event(:http_error), do: {:http_error, make_ref(), :boom}
  defp sample_event(:worker_crashed), do: {:worker_crashed, make_ref(), %RuntimeError{}, []}
  defp sample_event(:worker_down), do: {:worker_down, self(), :killed}
  defp sample_event(:worker_started), do: {:worker_started, make_ref(), self(), :http}
  defp sample_event(:llm_error), do: {:llm_error, make_ref(), "boom"}
  defp sample_event(:append_result), do: {:append_result, :stale, nil}
  defp sample_event(:preflight_result), do: {:preflight_result, :fits}
  defp sample_event(:stop), do: {:stop, self()}
  defp sample_event(:stop_timer), do: :stop_timer
  defp sample_event(:timer_armed), do: {:timer_armed, :stop_timer, make_ref()}
  defp sample_event(:compaction_request), do: {:compaction_request, {:tool_call, %{}, 1, 10}}
  defp sample_event(:compaction_ok), do: {:compaction_ok, %{summary: "s"}}
  defp sample_event(:commit_done), do: {:commit_done}
  defp sample_event(:commit_error), do: {:commit_error, :boom}
  defp sample_event(:compaction_error), do: {:compaction_error, :boom, nil}
  defp sample_event(:retry_compaction), do: :retry_compaction
  defp sample_event(:loop_ack), do: :loop_ack
  defp sample_event(:blocked), do: {:blocked, :needs_repair, nil}
  defp sample_event(:unblocked), do: {:unblocked}
  defp sample_event(:workspace_notice), do: :workspace_notice
  defp sample_event(:tool_results), do: {:tool_results, make_ref(), []}
  defp sample_event(:child_spawned), do: {:child_spawned, "kid", make_ref(), false}
  defp sample_event(:child_completed), do: {:child_completed, "kid", "resp", %{}}
  defp sample_event(:child_failed), do: {:child_failed, "kid", :crashed}
  defp sample_event(:child_terminated), do: {:child_terminated, "kid", :killed}
  defp sample_event(:abandon_child), do: {:abandon_child, "kid"}
end
