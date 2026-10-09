defmodule MachineBoundaryDeliveryTest do
  @moduledoc false
  # The turn-boundary inbox delivery contract (issue #15) and the parked /
  # queued-message visibility contract that peek-then-consume establishes
  # (#26): which drain outcome consumes the queue, what the give-up paths do
  # with the message, and what the post-compaction resume does with it. It
  # lives beside `machine_test.exs` rather than inside it because that file is
  # at the credo source-file cap. Behavior contract carried by the tests +
  # inline `#` comments, same as the rest of the machine contract.

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Compaction
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Messages.Part
  alias Nest.Tokens.ConversationSize

  describe "turn-boundary inbox delivery (issue #15)" do
    test "a queued message is drained at the boundary and the phase stays :generating" do
      # intentional: at the `:iterate` boundary reached after a tool batch or
      # a final assistant ack the wire sequence is complete and nothing is in
      # flight, so a queued inbox message is drained before the next request.
      # The phase must NOT pass through `:idle`: a transient idle would
      # resolve an idle-based `agents-query` wait with the pre-delivery answer
      # and would fire `:child_completed` at a parent.
      for {label, tail} <- [{"tool", tool_tail()}, {"assistant", assistant_tail()}] do
        {:ok, actions, next} = Machine.step(boundary_state(tail, inbox_count: 1), :iterate)

        assert {:drain_inbox} in actions, "#{label} tail must drain the inbox"

        refute Enum.any?(actions, &match?({:spawn_http, _}, &1)),
               "#{label} tail must not dispatch"

        assert next.phase == :generating and next.kind == :chat
        assert Machine.status_for(next) == :streaming
      end
    end

    test "no boundary delivery without a queued message, or while the turn is finalizing" do
      # intentional: three ways "nothing queued" is expressed — the
      # hand-built-ctx default (no key at all), an explicit 0, and nil (which
      # is NOT an empty inbox: `nil > 0` is true in Erlang term order, hence
      # the `is_integer/1` guard in the transition). `force_finalize` keeps
      # its "wrap this turn up now" meaning, so the queued message waits for
      # the turn end.
      cases = [
        {[], "absent inbox_count"},
        {[inbox_count: 0], "inbox_count 0"},
        {[inbox_count: nil], "inbox_count nil"},
        {[inbox_count: 1, force_finalize: true], "force_finalize"}
      ]

      for {opts, label} <- cases do
        {:ok, actions, next} = Machine.step(boundary_state(tool_tail(), opts), :iterate)

        refute {:drain_inbox} in actions, "#{label} must not drain the inbox"
        assert Enum.any?(actions, &match?({:spawn_http, _}, &1)), "#{label} must dispatch"
        assert next.phase == :generating and next.kind == :chat
      end
    end

    test "no boundary delivery onto a just-opened turn or an unanswered tool_use" do
      # intentional: the tail-tag check excludes the just-opened-turn shape
      # (the machine itself just appended the user message, e.g. the
      # compaction resume path). The position inside the `[]` branch of the
      # unpaired-tool-use case keeps an `{:assistant, _}` tail that still
      # carries unanswered `Part.ToolUse` out of the drain: appending a user
      # message there would be refused by `Repair` and fail the turn, so the
      # pending tool call is preflighted instead. `last_wire_role/1` is not
      # usable for the tail check (it maps `:tool` to `:user`, and a tool tail
      # is exactly the case we deliver into).
      {:ok, user_actions, user_next} =
        Machine.step(boundary_state([{:user, user()}], inbox_count: 1), :iterate)

      refute {:drain_inbox} in user_actions
      assert Enum.any?(user_actions, &match?({:spawn_http, _}, &1))
      assert user_next.phase == :generating

      {:ok, use_actions, use_next} =
        Machine.step(
          boundary_state([{:user, user()}, assistant_tool_call()], inbox_count: 1),
          :iterate
        )

      refute {:drain_inbox} in use_actions
      assert Enum.any?(use_actions, &match?({:preflight, _, _, _}, &1))
      assert use_next.phase == :generating
    end

    test "the :generating :inbox_drain event starts the delivered turn in place" do
      # intentional: the drained message is appended as a user message and the
      # turn continues in `:generating` — the same body as the `:idle` clause,
      # but without passing through idle: no `{:finalize, _}` is emitted, so
      # no parent notification fires and no transient idle is broadcast.
      entries = [inbox_entry()]
      m = boundary_state(tool_tail(), inbox_count: 1)

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, entries, "queued payload"})

      assert Enum.any?(actions, fn
               {:append, {:user, %Nest.Messages.User{parts: [%Part.Text{text: text}]}}} ->
                 text =~ "[mode: chat]" and text =~ "queued payload"

               _ ->
                 false
             end)

      assert :iterate in actions
      refute Enum.any?(actions, &match?({:finalize, _}, &1))
      assert next.phase == :generating and next.kind == :chat
      assert Machine.status_for(next) == :streaming
      # A fresh turn budget for the delivered message, as the `:idle` drain
      # gives it.
      assert next.work.iteration == 0
      assert next.work.force_finalize == false
      Machine.validate!(next)
    end

    test "a delivered message that fits appends first and consumes the queue after" do
      # intentional: the drain only *peeks* (issue #26) — the executor leaves
      # `state.live.inbox` alone — so the entries are still queued and still on
      # the wire until the branch that actually appended them consumes them.
      # The consume therefore rides in the same action list as the `{:append,
      # _}` and the `:iterate`, and its position AFTER the append is
      # load-bearing: an append the appender refuses halts the list with
      # `{:append_result, :invalid, _}`, so the consume never runs and the
      # entries stay queued and visible — the message is never in neither the
      # queue nor the transcript. A chat request (which never queued anything)
      # emits no consume at all.
      entries = [inbox_entry()]
      m = boundary_state(tool_tail(), inbox_count: 1)

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, entries, "queued payload"})

      append_at = index_of(actions, &match?({:append, _}, &1))

      assert append_at < index_of(actions, &match?({:consume_inbox, _}, &1))
      assert append_at < index_of(actions, &(&1 == :iterate))
      assert {:consume_inbox, ^entries} = List.last(actions -- [:iterate])

      assert next.phase == :generating and next.kind == :chat

      # A chat request has no queue behind it, so there is nothing to consume.
      {:ok, request_actions, _next} =
        Machine.step(idle_state(), {:chat_request, {:user_message, user()}})

      refute Enum.any?(request_actions, &match?({:consume_inbox, _}, &1))
      assert Enum.any?(request_actions, &match?({:append, _}, &1))
    end

    test "a delivered message that needs compaction stays queued and parks nothing" do
      # intentional: `start_chat/3` owns the fits decision. When the projected
      # turn needs a compaction the drained batch is NOT consumed — under
      # peek-then-consume the executor never cleared it — so the message stays
      # queued and visible (count > 0) for the whole compaction, and the
      # resume's in-place drain re-delivers it once the context has shrunk.
      # Nothing is parked on `pending_user_message`: that slot belongs to the
      # chat-request path, which has no queue to re-deliver from.
      base = boundary_state(two_turn_tool_tail(), inbox_count: 1)
      projected = base.work.ctx.messages ++ [Dispatch.build_user_message("queued", "chat")]

      m = %{
        base
        | work: %{
            base.work
            | ctx: %{base.work.ctx | context_limit: needs_compaction_limit(projected)}
          }
      }

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, [inbox_entry()], "queued"})

      refute Enum.any?(actions, &match?({:consume_inbox, _}, &1))
      refute Enum.any?(actions, &match?({:append, _}, &1))
      refute Enum.any?(actions, &match?({:restore_inbox, _}, &1))
      assert next.kind == :compaction
      assert {:compaction, staged, nil} = next.entry
      assert is_list(staged)
      assert next.pending_user_message == nil
      Machine.validate!(next)
    end

    test "a chat request that needs compaction still parks its message" do
      # intentional: the chat request path has no inbox entries to re-deliver,
      # so it keeps the parking contract: the built message rides on
      # `pending_user_message` and `resume_with_pending/1` appends it after the
      # commit.
      base = idle_state(two_turn_tool_tail())
      projected = base.work.ctx.messages ++ [user()]

      m = %{
        base
        | work: %{
            base.work
            | ctx: %{base.work.ctx | context_limit: needs_compaction_limit(projected)}
          }
      }

      {:ok, actions, next} = Machine.step(m, {:chat_request, {:user_message, user()}})

      refute Enum.any?(actions, &match?({:consume_inbox, _}, &1))
      assert next.kind == :compaction
      assert {:user_message, %Nest.Messages.User{}} = next.pending_user_message
      Machine.validate!(next)
    end

    test "a delivered message that cannot compact blocks and stays queued" do
      # intentional: when the turn cannot fit and cannot be compacted the agent
      # blocks on `:context_overflow`. Nothing is consumed and nothing is
      # restored — the entries were never cleared, so `{:restore_inbox, _}` is
      # gone from the vocabulary — and the message stays queued on the wire.
      # `{:unblocked}`'s existing `{:drain_inbox}` re-attempts it once the
      # operator has acted.
      entries = [inbox_entry()]
      m = boundary_state(tool_tail(), inbox_count: 1, context_limit: 1)

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, entries, "queued"})

      refute Enum.any?(actions, &match?({:consume_inbox, _}, &1))
      refute Enum.any?(actions, &match?({:append, _}, &1))
      refute Enum.any?(actions, &match?({:restore_inbox, _}, &1))
      assert next.phase == :context_overflow
      assert Machine.status_for(next) == :context_overflow
    end
  end

  describe "compaction loop ack keeps a held message" do
    test "a parked message is appended before the drain; without one it is a bare drain" do
      # intentional: `start_chat/3`'s `:needs_compaction` branch parks the
      # drained message on `pending_user_message` while the executor has
      # already consumed `state.live.inbox`, so `:loop_ack` must re-append it
      # — a bare `{:drain_inbox}` would drop the content silently.
      #
      # Every shape `Phase.unwrap_user/1` accepts is re-appended, not dropped:
      # the drain path stores `{:user_message, {:user, user}}` (the executor's
      # `Dispatch.build_user_message/2` tuple), a chat request stores
      # `{:user_message, user}` (a bare struct), and `{content, mode}` is the
      # legacy held shape this repo's fixtures still use.
      {:user, user} = Dispatch.build_user_message("held message", "chat")

      held_shapes = [
        {{:user_message, {:user, user}}, "held message"},
        {{:user_message, user}, "held message"},
        {{"legacy held message", "chat"}, "legacy held message"}
      ]

      for {held, expected} <- held_shapes do
        {:ok, actions, next} = Machine.step(loop_detected_state(held), :loop_ack)

        assert [
                 {:append, {:user, %Nest.Messages.User{parts: [%Part.Text{text: text}]}}},
                 {:drain_inbox}
               ] =
                 actions

        assert text =~ expected
        assert next.phase == :idle and next.kind == :chat
        assert next.pending_user_message == nil
        assert next.loop_count == 0
        Machine.validate!(next)
      end

      # A value `Phase.unwrap_user/1` cannot unwrap is logged and treated as
      # nothing held, so a declared event never raises and the drop is visible.
      log =
        capture_log(fn ->
          {:ok, actions, next} = Machine.step(loop_detected_state({:bogus, :shape}), :loop_ack)

          assert actions == [{:drain_inbox}]
          assert next.pending_user_message == nil
        end)

      assert log =~ "unrecognized pending_user_message"
      assert log =~ "{:bogus, :shape}"

      # Nothing parked: the loop breaker is still just the idle transition
      # plus the drain.
      {:ok, actions, next} = Machine.step(loop_detected_state(nil), :loop_ack)

      assert actions == [{:drain_inbox}]
      assert next.phase == :idle
      assert next.pending_user_message == nil
      Machine.validate!(next)
    end

    test "queued entries are appended and consumed without re-entering the compaction decision" do
      # intentional: under peek-then-consume the entries of a drain that needed
      # a compaction are still queued — nothing was parked — so a bare
      # `{:drain_inbox}` here would re-preflight them and re-stage the very
      # compaction the ack just gave up on (operator-gated by the `loop_count`
      # reset, but still the loop the ack exists to break). `{:drain_inbox,
      # :append}` builds the combined message from the batch and consumes it
      # without `start_chat/3`.
      {:ok, actions, next} = Machine.step(loop_detected_state(nil, inbox_count: 2), :loop_ack)

      assert actions == [{:drain_inbox, :append}]
      assert next.phase == :idle
      assert next.loop_count == 0
      Machine.validate!(next)

      # Both held and queued: the parked message is appended first (the machine
      # holds it), then the queued batch is appended and consumed.
      {:user, _user} = held = Dispatch.build_user_message("held message", "chat")
      entry = {:user_message, held}

      {:ok, actions, next} = Machine.step(loop_detected_state(entry, inbox_count: 1), :loop_ack)

      assert [{:append, {:user, %Nest.Messages.User{}}}, {:drain_inbox, :append}] = actions
      assert next.phase == :idle
      assert next.pending_user_message == nil
      Machine.validate!(next)
    end
  end

  describe "compaction give-up and resume keep the message visible" do
    test ":reserve_exhausted does not strand the message in any of its three arms" do
      # intentional: `:reserve_exhausted` means the model cannot fit the system
      # prompt plus the compaction request into its reserve, so re-draining
      # would loop (start_chat -> :needs_compaction -> stage -> here). The
      # parked chat request is appended before anything else and its slot
      # cleared; the drain path's entries stay queued and the agent blocks (a
      # drain would re-stage the failing compaction); with nothing held and
      # nothing queued the agent idles as before.
      overflow = {:broadcast, {:overflow, :reserve_exhausted, "compact"}, nil}

      # The chat-request arm: the built message is parked on the machine and no
      # queue holds it, so it must be appended (the `:loop_ack` precedent).
      held = %{reserve_state() | pending_user_message: {:user_message, user()}}
      {:ok, actions, next} = Compaction.stage(held, nil, nil)

      assert [^overflow, {:append, {:user, %Nest.Messages.User{}}}] = actions
      refute Enum.any?(actions, &match?({:restore_inbox, _}, &1))
      assert next.phase == :idle
      assert next.pending_user_message == nil
      Machine.validate!(next)

      # The inbox arm: the entries are still queued, so block instead of
      # draining — a drain would re-run the decision that just failed.
      {:ok, actions, next} = Compaction.stage(reserve_state(inbox_count: 1), nil, nil)

      assert [^overflow] = actions
      assert next.phase == :context_overflow
      assert Machine.status_for(next) == :context_overflow
      Machine.validate!(next)

      # Nothing held and nothing queued: idle, as before.
      {:ok, actions, next} = Compaction.stage(reserve_state(), nil, nil)

      assert [^overflow] = actions
      assert next.phase == :idle
      Machine.validate!(next)

      # A held shape `Phase.unwrap_user/1` cannot unwrap is logged and treated
      # as nothing held — the `:loop_ack` contract, asserted for this branch
      # too: a declared event never raises, and the drop is visible.
      log =
        capture_log(fn ->
          bogus = %{reserve_state() | pending_user_message: {:bogus, :shape}}
          {:ok, actions, next} = Compaction.stage(bogus, nil, nil)

          assert [^overflow] = actions
          assert next.phase == :idle
        end)

      assert log =~ "unrecognized pending_user_message"
      assert log =~ "{:bogus, :shape}"
    end

    test "the post-compaction resume re-drains in place while the queue still holds the message" do
      # intentional: under peek-then-consume the message that needed the
      # compaction is still queued, so the resume delivers it straight from
      # `:generating`. Entering `:idle` first would broadcast a transient idle
      # (which resolves an idle-based wait with the pre-delivery answer) and
      # `{:finalize, :clean}` a turn that is really continuing — the #15
      # property this path preserves.
      queued = %{reserve_state(inbox_count: 1) | entry: {:compaction, [], nil}}
      {:ok, actions, next} = Compaction.resume(queued)

      assert actions == [{:drain_inbox}]
      assert next.phase == :generating and next.kind == :chat
      assert Machine.status_for(next) == :streaming
      assert next.entry == nil
      Machine.validate!(next)

      # Nothing queued: the resume settles to idle and finalizes as before.
      empty = %{reserve_state() | entry: {:compaction, [], nil}}
      {:ok, actions, next} = Compaction.resume(empty)

      assert actions == [{:finalize, :clean}, {:drain_inbox}]
      assert next.phase == :idle
      Machine.validate!(next)
    end
  end

  # --- helpers ---

  # A machine in the loop-breaker's blocked phase, holding `held` (or nothing)
  # on the pending-message slot. Blocked phases carry no worker kind.
  defp loop_detected_state(held, opts \\ []) do
    base = generating_state()
    ctx = put_opt(base.work.ctx, opts, :inbox_count)

    %{
      base
      | phase: :compaction_loop_detected,
        loop_count: 3,
        pending_user_message: held,
        work: %{base.work | worker_kind: nil, ctx: ctx}
    }
  end

  # The same fixture in `:idle`: the chat-request path's entry point.
  defp idle_state(tail \\ []) do
    base = boundary_state(tail, [])
    %{base | phase: :idle, work: %{base.work | worker_kind: nil}}
  end

  # The window between "the system prompt alone fits" and "everything fits" is
  # a few tokens wide; derive the limit from the same estimator the transition
  # uses (8_191 is one token under `Reserve`'s 8_192 floor). The precondition
  # assertion fails loudly if that floor moves, instead of surfacing as an
  # unrelated `next.kind` mismatch.
  defp needs_compaction_limit(projected) do
    limit = ConversationSize.size(projected) + 8_191

    assert Dispatch.preflight_decision(projected, limit) == :needs_compaction,
           "the fixture must force the :needs_compaction branch"

    limit
  end

  # `Enum.find_index/2` returns nil for "not found", and every integer is
  # `< nil` in Erlang term order, so an ordering assertion built on it passes
  # vacuously when the action is absent. Flunk instead.
  defp index_of(actions, fun) do
    Enum.find_index(actions, fun) || flunk("no action matching in #{inspect(actions)}")
  end

  # A machine whose compaction plan cannot even be staged: with no system
  # message and no vocation, `Dispatch.compaction_plan/1` reports
  # `{:error, :reserve_exhausted}`.
  defp reserve_state(opts \\ []) do
    base = idle_state()
    ctx = put_opt(%{base.work.ctx | messages: []}, opts, :inbox_count)
    %{base | work: %{base.work | ctx: ctx}}
  end

  defp put_opt(ctx, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Map.put(ctx, key, value)
      :error -> ctx
    end
  end

  # A `:generating` machine whose ctx ends on `tail`. `inbox_count` is
  # omitted unless asked for, so the tests cover the hand-built-ctx shape
  # (no key) as well as explicit 0/nil.
  defp boundary_state(tail, opts) do
    base = generating_state()
    ctx = base.work.ctx

    ctx = %{
      ctx
      | messages: ctx.messages ++ tail,
        context_limit: Keyword.get(opts, :context_limit, ctx.context_limit)
    }

    ctx = put_opt(ctx, opts, :inbox_count)

    %{
      base
      | work: %{
          base.work
          | ctx: ctx,
            force_finalize: Keyword.get(opts, :force_finalize, false)
        }
    }
  end

  # The boundary right after a tool batch lands: the results answer the
  # assistant's tool call, so nothing is unanswered and nothing is in flight.
  defp tool_tail, do: [{:user, user()}, assistant_tool_call(), tool_result()]

  # An `{:assistant, _}` tail. Defensive today, not a live boundary: every
  # `:iterate` site was enumerated and none reaches it (a carried tool call
  # has a `Part.ToolUse` so it preflights, a carried assistant response
  # finalizes instead of iterating, the truncation/silent re-prompt nudges
  # with a user message). Keeping the drain correct for it matters anyway:
  # without the drain `dispatch_http/1` would ship the assistant tail and
  # `Preflight.validate_request/1` would fail the turn on
  # `:no_trailing_assistant`.
  defp assistant_tail, do: [{:user, user()}, assistant_text()]

  # Two user turns, so a compaction has a non-empty head to summarize: the
  # `:needs_compaction` branch is unreachable when the head is empty (that is
  # `:cannot_compact`).
  defp two_turn_tool_tail do
    [{:user, user()}, assistant_text(), {:user, user()}, assistant_tool_call(), tool_result()]
  end

  defp assistant_tool_call do
    {:assistant,
     %Nest.Messages.Assistant{
       parts: [%Part.ToolUse{id: "c1", name: "shell-cmd", arguments: %{}}]
     }}
  end

  defp assistant_text do
    {:assistant, %Nest.Messages.Assistant{parts: [%Part.Text{text: "ack"}]}}
  end

  defp tool_result do
    {:tool,
     %Nest.Messages.Tool{
       parts: [
         %Part.ToolResult{tool_call_id: "c1", name: "shell-cmd", content: "ok", is_error: false}
       ]
     }}
  end

  defp inbox_entry do
    %{
      from: "peer",
      content: "queued payload",
      timestamp: DateTime.utc_now(),
      kind: :agent,
      mode: nil
    }
  end

  defp user do
    %Nest.Messages.User{index: nil, parts: [%Nest.Messages.Part.Text{text: "hi"}], api_logs: []}
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

  # `worker_ref`/`active_worker` are nil, matching every real `:iterate`
  # boundary: `Phase.enter/4` clears them on the transition into `:generating`
  # and `:iterate` is only emitted after the append that follows it, so
  # "nothing is in flight" is the fixture's real precondition.
  defp generating_state do
    Machine.new(
      phase: :generating,
      kind: :chat,
      work: %Machine.Work{
        worker_kind: :http,
        worker_ref: nil,
        active_worker: nil,
        ctx: ctx(),
        max_iterations: 10
      }
    )
  end
end
