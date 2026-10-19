defmodule MachineCompactionTest do
  @moduledoc false
  # NOTE: per the project rule, this file's behavior contract is carried by
  # the tests + inline # comments below, not by this moduledoc.

  use ExUnit.Case, async: true

  import Nest.TestSupport.MachineTestHelpers

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Response
  alias Nest.Agents.Agent.Machine.Turn
  alias Nest.Agents.Agent.Repair
  alias Nest.Messages.Part
  alias Nest.Tokens.ConversationSize

  # A conversation the transcript is too big for, at any limit near its own size:
  # a user/assistant exchange ahead of a large `user` row, so `PreFlight` does not
  # call the compaction a no-op (which is the `:cannot_compact` arm).
  defp near_limit_conversation do
    [
      system_message(),
      {:user,
       %Nest.Messages.User{
         index: 1,
         parts: [%Nest.Messages.Part.Text{text: "hello"}],
         api_logs: []
       }},
      {:assistant,
       %Nest.Messages.Assistant{
         index: 2,
         parts: [%Nest.Messages.Part.Text{text: "hi"}],
         api_logs: []
       }},
      {:user,
       %Nest.Messages.User{
         index: 3,
         parts: [%Nest.Messages.Part.Text{text: String.duplicate("word ", 20_000)}],
         api_logs: []
       }}
    ]
  end

  defp notice_step(messages, limit, event \\ {:workspace_notice, notice_values()}) do
    machine = state_at(:idle, ctx: %{ctx() | messages: messages, context_limit: limit})

    {:ok, _actions, next} = Machine.step(machine, event)

    next
  end

  defp notice_values do
    %{kind: :workspace, workspace: "/tmp/x", network_access: true, backend: "bwrap"}
  end

  # A model change's facts, as `ModelHandler.facts/2` builds them (hand-built
  # here so the machine test needs no catalog).
  defp model_facts do
    %{kind: :model, model: "m", verdict: :unknown, context_limit: 100_000}
  end

  describe "compaction decisions" do
    test "the loop-breaker blocks after the consecutive cap" do
      m = %{state_at(:idle) | loop_count: 3, entry: {:compaction, nil, nil}}
      {:ok, actions, next} = Machine.Compaction.stage(m, nil)

      assert next.phase == :compaction_loop_detected
      assert Enum.any?(actions, &match?({:broadcast, {:compaction_loop, _, _, _}, _}, &1))
    end

    test "a compaction that cannot start says so in the transcript" do
      # `:system_oversized`: the rendered system prompt does not fit the 25%
      # budget, so the plan fails before any request exists. Every staging
      # failure leaves a notice, and the wording differs per arm, so this pins
      # the oversized one (the three `:reserve_exhausted` arms are pinned in
      # `MachineBoundaryDeliveryTest`).
      m = state_at(:idle, ctx: %{ctx() | context_limit: 1})

      {:ok, actions, next} = Machine.Compaction.stage(m, nil)

      assert next.phase == :context_overflow
      assert Machine.status_for(next) == :context_overflow

      notice =
        Enum.find_value(actions, fn
          {:append, {:user, %{parts: [%Part.Text{text: text}]}}} -> text
          _ -> nil
        end)

      assert notice, "expected a notice row for the failed staging"
      assert notice =~ "Compaction did not start"
      assert notice =~ "system prompt is too large"
    end

    test "a deferred assistant reply stays blocked on compaction failure" do
      m = state_at(:idle)
      reply = {:assistant_response, user(), 1, 5}
      {:ok, actions, next} = Machine.Compaction.compaction_failed(m, :boom, reply)

      assert next.phase == :compaction_failed
      assert Enum.any?(actions, &match?({:broadcast, {:compaction_error, _}, _}, &1))
    end

    test "resume emits the deferred space-environment notice pair" do
      base = state_at(:idle)

      m = %{base | entry: {:compaction, nil, notice_values()}}
      {:ok, actions, next} = Machine.Compaction.resume(m)

      assert next.phase == :idle
      assert Enum.any?(actions, &match?({:append_many, _}, &1))

      # The space's flag is cleared by the executor, *after* the append: until
      # this ran, the row was the only record that the agent still owed the
      # notice (a stop, archive, crash or deploy before the commit loses the
      # entry, and the next start must announce it). The action carries the
      # values, because the executor clears the row only while the space still
      # holds them.
      assert {:clear_space_notice, values} = List.keyfind(actions, :clear_space_notice, 0)
      assert values == notice_values()

      assert Enum.find_index(actions, &match?({:append_many, _}, &1)) <
               Enum.find_index(actions, &match?({:clear_space_notice, _}, &1))
    end

    # A space-environment notice lives on the compaction entry that will append
    # it — `{:compaction, carried, values}` — and nowhere else. So the only shape
    # that carries it forward is a compaction that actually started; the
    # `:reserve_exhausted` rest and the two blocks drop it with the turn, which is
    # why the caller keeps the space's flag on those outcomes.
    #
    # Pure: no agent, no DB, no daemon. The transcript is built from the
    # estimator's own size so the test does not encode a chars-per-token constant.
    test "a staged compaction carries the values on its entry, and a reserve that cannot hold one stages nothing" do
      messages = near_limit_conversation()
      size = ConversationSize.size(messages)

      # `:needs_compaction` (the transcript plus the reserve does not fit) *and*
      # `compute_summary_budget/4` can still plan: the compaction is in flight and
      # carries the values for `Compaction.resume/1`.
      staged = notice_step(messages, size + 4_000)

      assert staged.phase == :generating
      assert staged.kind == :compaction
      assert {:compaction, nil, values} = staged.entry
      assert is_map(values)

      # The budget reminder's slot is untouched: it is not the notice's.
      assert staged.work.pending_notice == nil

      # The same transcript with no headroom left at all: the request cannot be
      # fitted into the reserve, so `Compaction.stage/2` *rests* — and there is no
      # entry, so there is nothing anywhere for a later compaction to consume.
      rested = notice_step(messages, size + 1)

      assert rested.phase == :idle
      assert Machine.status_for(rested) == :idle
      assert rested.entry == nil
      assert rested.work.pending_notice == nil
    end

    # A model change rides the same three arms as a space-environment change —
    # the pair when it fits, the compaction's entry when one is needed, the
    # overflow block when nothing can help — because the agent's prompt states the
    # model's facts and is never rebuilt. Its entry carries the *facts*, and the
    # resume that appends them has no space flag to clear.
    test "a model notice stages on the compaction entry, resumes as its own pair, and blocks when nothing fits" do
      messages = near_limit_conversation()
      size = ConversationSize.size(messages)
      facts = model_facts()

      staged = notice_step(messages, size + 4_000, {:model_notice, facts})

      assert staged.phase == :generating
      assert staged.kind == :compaction
      assert {:compaction, nil, ^facts} = staged.entry

      {:ok, actions, resumed} = Machine.Compaction.resume(staged)

      assert resumed.phase == :idle
      assert {:append_many, [notice_row, ack_row]} = List.keyfind(actions, :append_many, 0)

      assert {:user, %{parts: [%Part.Text{text: notice}]}} = notice_row
      assert notice =~ "Your model changed. It is now \"m\"."
      assert notice =~ "Nothing declares whether it accepts image input"
      assert notice =~ "Its context limit is 100000 tokens"
      assert {:assistant, %{parts: [%Part.Text{text: "Model change confirmed."}]}} = ack_row

      # Nothing to clear: the model is the row's own property, so unlike the
      # space's notice there is no "not told yet" flag anywhere.
      refute List.keyfind(actions, :clear_space_notice, 0)

      # No headroom for a compaction either: the notice must not be appended into
      # a request that cannot hold it, so the agent blocks with the banner.
      machine = state_at(:idle, ctx: %{ctx() | messages: messages, context_limit: 1})
      {:ok, blocked_actions, blocked} = Machine.step(machine, {:model_notice, facts})

      assert blocked.phase == :context_overflow
      assert blocked.entry == nil

      assert Enum.any?(
               blocked_actions,
               &match?({:broadcast, {:overflow, :reserve_exhausted, _}, _}, &1)
             )

      refute Enum.any?(blocked_actions, &match?({:append_many, _}, &1))
    end

    test "the compaction that carries the notice appends it, and one that does not resumes its reply" do
      # The notice is the compaction *entry's*, so the branch is decided by the
      # entry and not by a slot some other turn could have filled. Both halves
      # below are the same carried reply; only the entry's notice differs.
      carried = {:assistant_response, %Nest.Messages.Assistant{parts: []}, 0, 5}
      base = state_at(:idle)

      noticing = %{base | entry: {:compaction, carried, notice_values()}}
      {:ok, notice_actions, notice_next} = Machine.Compaction.resume(noticing)

      assert Enum.any?(notice_actions, &match?({:append_many, _}, &1))
      assert notice_next.phase == :idle

      plain = %{base | entry: {:compaction, carried, nil}}
      {:ok, actions, next} = Machine.Compaction.resume(plain)

      refute Enum.any?(actions, &match?({:append_many, _}, &1)),
             "a compaction with no notice must not append one"

      # The carried reply's own resume ran — it settles the turn it was carried
      # across (`:compaction_carry`), rather than resting on a notice.
      assert {:finalize, :clean} in actions
      assert next.phase == :idle
      assert next.entry == nil
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
    # `Response.dispatch/2` sets `compactor? = match?({:compaction, _, _}, m.entry)`
    # and `Machine.Turn.classify_response/1` checks that FIRST and
    # unconditionally — so the next chat turn's reply would be classified
    # `:compaction`, and `commit_compaction/2` would archive the whole active
    # segment and persist that reply as the summary.
    test "a compaction entry does not survive into the next chat turn" do
      failed = %{state_at(:compaction_failed, kind: :compaction) | entry: {:compaction, nil, nil}}
      {:ok, _actions, looped} = Machine.step(%{failed | loop_count: 3}, :retry_compaction)

      assert looped.phase == :compaction_loop_detected
      # intentional: the entry SURVIVES here. `:compaction_loop_detected` is
      # the phase entered through `enter_blocked/2`, which deliberately skips
      # the turn-scoping that clears it — so a `:compaction_failed` retry can
      # still find it. (Note `Compaction.retry/1` itself reads
      # `mid_turn_entry`, not `entry`; the entry is kept here for the retry
      # path's own reasons, not because retry reads this field.)
      assert looped.entry == {:compaction, nil, nil}

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

    # BLOCKER, found by the third review of PR #137. The space notice used to
    # live in `work.pending_notice`, and `Phase.block/4` never clears that slot —
    # so a compaction that failed left the map behind, `{:unblocked}` left it
    # behind, and the next compaction carrying a reply hit `resume/1`'s notice
    # clause: it appended a *stale* environment pair, skipped
    # `resume_carried_reply/2`, and rested — giving up any peer reply the machine
    # still owed. The notice is on the entry now, so the sequence cannot reach a
    # resume at all.
    test "a failed compaction cannot hand its notice to a later one" do
      values = notice_values()
      staged = %{state_at(:committing) | entry: {:compaction, nil, values}}

      # A failure with nothing carried blocks, and the entry stays: a retry
      # re-sends the same request for the same compaction turn.
      {:ok, _actions, failed} = Machine.Compaction.compaction_failed(staged, :boom, nil)
      assert failed.phase == :compaction_failed
      assert {:compaction, nil, ^values} = failed.entry

      # Leaving that phase drops the entry — and the notice with it, because the
      # notice is not anywhere else.
      {:ok, _actions, unblocked} = Machine.step(failed, {:unblocked})
      assert unblocked.phase == :idle
      assert unblocked.entry == nil
      assert unblocked.work.pending_notice == nil

      # The next compaction is a different turn with its own carried reply, and
      # it resumes the reply rather than appending anything stale.
      carried = {:assistant_response, %Nest.Messages.Assistant{parts: []}, 0, 5}
      later = %{unblocked | entry: {:compaction, carried, nil}}
      {:ok, actions, next} = Machine.Compaction.resume(later)

      refute Enum.any?(actions, &match?({:append_many, _}, &1))
      assert {:finalize, :clean} in actions
      assert next.phase == :idle
    end

    test "a compaction entry does not survive an unblock either" do
      m = %{state_at(:needs_repair, kind: :compaction) | entry: {:compaction, nil, nil}}

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
      compactor?: match?({:compaction, _, _}, entry),
      force_finalize: false,
      has_tool_calls: false,
      iteration: 0,
      max_iterations: 10,
      empty_assistant?: false,
      truncated?: false,
      silent?: false
    })
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

      assert {:compaction, {:assistant_response, {:assistant, _}, 0, 10}, nil} = next.entry
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
          entry: {:compaction, carried, nil}
        )

      {:ok, actions, next} = Machine.step(machine, {:commit_done})

      assert {:finalize, :clean} in actions
      refute Enum.any?(actions, &match?({:notify_parent, _}, &1))
      assert next.phase == :idle
    end
  end
end
