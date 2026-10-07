defmodule MachineBoundaryDeliveryTest do
  @moduledoc false
  # The turn-boundary inbox delivery contract (issue #15). It lives beside
  # `machine_test.exs` rather than inside it because that file is at the
  # credo source-file cap. Behavior contract carried by the tests + inline
  # `#` comments, same as the rest of the machine contract.

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.Machine
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

    test "a delivered message that needs compaction is held for the compaction turn" do
      # intentional: `start_chat/3` owns the fits decision. When the projected
      # turn needs a compaction the drained message is held on
      # `pending_user_message` — on the machine only, not on the wire (the
      # executor has already emptied and rebroadcast the inbox), until the
      # compaction commits and `resume_with_pending/1` appends it — so the
      # compaction runs first and the content is not lost.
      m = boundary_state(two_turn_tool_tail(), inbox_count: 1)

      # The window between "the system prompt alone fits" and "everything
      # fits" is a few tokens wide; derive the limit from the same estimator
      # the transition uses (8_191 is one token under `Reserve`'s 8_192 floor).
      # The precondition assertion below fails loudly if that floor moves,
      # instead of surfacing as an unrelated `next.kind` mismatch.
      projected = m.work.ctx.messages ++ [Dispatch.build_user_message("queued", "chat")]
      limit = ConversationSize.size(projected) + 8_191

      assert Dispatch.preflight_decision(projected, limit) == :needs_compaction,
             "the fixture must force the :needs_compaction branch"

      m = %{m | work: %{m.work | ctx: %{m.work.ctx | context_limit: limit}}}

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, [inbox_entry()], "queued"})

      refute Enum.any?(actions, &match?({:append, _}, &1))
      refute Enum.any?(actions, &match?({:restore_inbox, _}, &1))
      assert next.kind == :compaction
      assert {:compaction, staged, nil} = next.entry
      assert is_list(staged)

      assert {:user_message, {:user, %Nest.Messages.User{parts: [%Part.Text{text: text}]}}} =
               next.pending_user_message

      assert text =~ "queued"
      Machine.validate!(next)
    end

    test "a delivered message that cannot compact is restored to the inbox" do
      # intentional: when the turn cannot fit and cannot be compacted, the
      # agent blocks on `:context_overflow` and the drained entries go back to
      # the inbox (`{:restore_inbox, entries}`) rather than being dropped with
      # the drain that already consumed them.
      entries = [inbox_entry()]
      m = boundary_state(tool_tail(), inbox_count: 1, context_limit: 1)

      {:ok, actions, next} = Machine.step(m, {:inbox_drain, entries, "queued"})

      assert Enum.any?(actions, &match?({:restore_inbox, ^entries}, &1))
      refute Enum.any?(actions, &match?({:append, _}, &1))
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
  end

  # --- helpers ---

  # A machine in the loop-breaker's blocked phase, holding `held` (or nothing)
  # on the pending-message slot. Blocked phases carry no worker kind.
  defp loop_detected_state(held) do
    base = generating_state()

    %{
      base
      | phase: :compaction_loop_detected,
        loop_count: 3,
        pending_user_message: held,
        work: %{base.work | worker_kind: nil}
    }
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

    ctx =
      case Keyword.fetch(opts, :inbox_count) do
        {:ok, count} -> Map.put(ctx, :inbox_count, count)
        :error -> ctx
      end

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
    %{from: "peer", content: "queued payload", timestamp: DateTime.utc_now()}
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
