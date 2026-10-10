defmodule MachineDebtTest do
  @moduledoc false
  # The reply obligation (issue #31 §1.2, §1.4, §1.5) at the machine level: the
  # shape of the debt map, the idle gate that reminds once and then gives up
  # rather than idling with the obligation standing, and the clear a successful
  # outbound send performs. It lives beside `machine_test.exs` because that file
  # is near the credo source-file cap. Behavior contract carried by the tests +
  # inline `#` comments, like the rest of the machine contract.

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Machine.Compaction
  alias Nest.Agents.Agent.Turn.Messages
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Messages.User
  alias Nest.Tokens.Budget

  describe "the debt map" do
    test "is keyed by sender name, one entry per peer, and never resets a reminder" do
      m = Machine.owe_replies(Machine.new(), ["alice", "bob", "alice"])

      # One key per distinct peer (decision 1: no per-query records), sorted for
      # the wire, and a repeat query from a sender is the same debt.
      assert Machine.owed_senders(m) == ["alice", "bob"]
      assert m.owed_replies == %{"alice" => 0, "bob" => 0}
      assert Machine.due_senders(m) == ["alice", "bob"]

      # One reminder is counted for every debtor at once, and a query that
      # arrives after a reminder does not hand out a second one (decision 10:
      # the budget is per debt, and the counter only resets when the debt
      # empties — which clearing a key does).
      reminded = Machine.count_reminders(m, Machine.due_senders(m))

      assert reminded.owed_replies == %{"alice" => 1, "bob" => 1}
      assert Machine.due_senders(reminded) == []
      assert Machine.owe_replies(reminded, ["alice"]).owed_replies == %{"alice" => 1, "bob" => 1}

      # The reset: once the debt set empties, the next query starts at zero.
      fresh = Machine.owe_replies(Machine.discharge_all(reminded), ["alice"])

      assert fresh.owed_replies == %{"alice" => 0}
      assert Machine.due_senders(fresh) == ["alice"]
    end

    test "ignores an unnamed sender and discharges one peer at a time" do
      # intentional: the obligation is keyed by name, so a query with no sender
      # has no key to owe; and a successful send clears the peer it reached
      # (decision 11's rule applied at the map) — a reply to alice leaves bob's
      # obligation standing, because the runtime matches no reply to a query and
      # cannot claim bob was answered.
      m = Machine.owe_replies(Machine.new(), [nil, "", "alice", "bob"])

      assert Machine.owed_senders(m) == ["alice", "bob"]

      after_alice = Machine.discharge_reply(m, "alice")

      assert Machine.owed_senders(after_alice) == ["bob"]
      assert Machine.owed_senders(Machine.discharge_reply(after_alice, nil)) == ["bob"]
      assert Machine.owed_senders(Machine.discharge_reply(after_alice, "nobody")) == ["bob"]
      assert Machine.discharge_all(after_alice).owed_replies == %{}
      assert Machine.due_senders(Machine.discharge_all(m)) == []
    end
  end

  describe "the idle gate" do
    test "a reply the agent still owes keeps the turn alive with one reminder" do
      {m, ref} = generating_with_debt(["alice"])

      {:ok, actions, next} = Machine.step(m, {:http_ok, ref, response(text: "all done")})

      # The reply is appended, then the reminder, then the turn continues — the
      # same shape as the truncation/silent re-prompt, and with no `{:finalize,
      # _}`: the turn is not over.
      assert [{:append, {:assistant, _}}, {:append, {:user, reminder}}, :iterate] =
               Enum.take(actions, -3)

      refute Enum.any?(actions, &match?({:finalize, _}, &1))
      assert next.phase == :generating and next.kind == :chat
      assert Machine.status_for(next) == :streaming
      assert next.owed_replies == %{"alice" => 1}

      # The reminder is the runtime's own user message: it names the debtor, it
      # does not quote the outstanding message (decision 4 — the agent looks that
      # up), and it carries no sender label and no mode prefix.
      assert %User{parts: [%Part.Text{text: text}], metadata: nil} = reminder
      assert text =~ "alice"
      refute text =~ "queued query"
      refute text =~ "[mode:"

      # The deferred `:iterate` dispatches the next request, exactly as the
      # re-prompt branch's does.
      {:ok, iterate_actions, m} = Machine.step(next, :iterate)
      assert Enum.any?(iterate_actions, &match?({:spawn_http, _}, &1))

      # The budget is one reminder per debt: the next would-be-idle transition
      # gives up instead. It discharges the debt rather than idling with it
      # standing — `agents-wait` reads an idle peer as one with no unpaid debt,
      # and §1.6 replaces this discharge with the honest notice to the requester.
      ref2 = make_ref()
      {:ok, [], m} = Machine.step(m, {:worker_started, ref2, self(), :http})

      {:ok, actions, final} = Machine.step(m, {:http_ok, ref2, response(text: "still nothing")})

      refute Enum.any?(actions, &match?({:append, {:user, _}}, &1))
      assert {:finalize, :clean} in actions

      # The settle carries the give-up action (`Machine.GiveUp`): it tells each
      # requester that no answer is coming and discharges the debt. The machine
      # itself still shows the obligation the action is about to read.
      assert Enum.any?(actions, &match?({:give_up_replies, :no_reminder}, &1))
      assert final.phase == :idle
      assert final.owed_replies == %{"alice" => 1}
      Machine.validate!(final)
    end

    test "the reminder names every debtor and quotes none of their messages" do
      {m, ref} = generating_with_debt(["alice", "bob"])

      {:ok, actions, next} = Machine.step(m, {:http_ok, ref, response(text: "all done")})

      assert text = reminder_text(actions)
      assert text =~ "alice" and text =~ "bob"
      refute text =~ "queued query"
      assert next.owed_replies == %{"alice" => 1, "bob" => 1}
    end

    test "a debt whose reminder is spent is not named, or counted, a second time" do
      # intentional: the budget is per debt, so the gate names only the senders
      # that are *due* and counts only those. A query that arrives after alice's
      # reminder must not re-arm alice's spent budget — the runtime gives up on
      # her debt at the next rest instead (decision 10).
      {m, ref} = generating_with_debt(["alice", "bob"])
      m = %{m | owed_replies: %{"alice" => 1, "bob" => 0}}

      {:ok, actions, next} = Machine.step(m, {:http_ok, ref, response(text: "all done")})

      assert text = reminder_text(actions)
      refute text =~ "alice"
      assert text =~ "bob"
      assert next.owed_replies == %{"alice" => 1, "bob" => 1}
    end

    test "a reminder that would not fit is not injected" do
      # intentional: a reminder that cannot fit the remaining content budget is
      # dropped (the `nudge_or_finalize/2` fit guard) — and because the runtime
      # can then no longer remind, the debt is discharged rather than left
      # standing behind an idle agent.
      {m, ref} = generating_with_debt(["alice"])
      response = response(text: "all done")
      projected = m.work.ctx.messages ++ [assistant_message(response)]
      m = %{m | work: %{m.work | ctx: %{m.work.ctx | context_limit: tight_limit(projected)}}}

      {:ok, actions, next} = Machine.step(m, {:http_ok, ref, response})

      refute Enum.any?(actions, &match?({:append, {:user, _}}, &1))
      assert {:finalize, :clean} in actions
      assert Enum.any?(actions, &match?({:give_up_replies, :no_reminder}, &1))
      assert next.phase == :idle
      assert next.owed_replies == %{"alice" => 0}
    end

    test "no reminder onto an assistant message that still carries a tool call" do
      # intentional: `:force_finalize` is classified before the tool-call
      # branches, so the wrap-up second chance can still come back with tool
      # calls. A user message appended onto an unanswered `tool_use` is refused
      # by `Repair.classify_live/2`, and that refusal fails the turn — so the
      # gate gives up instead of appending one.
      {m, ref} = generating_with_debt(["alice"])
      m = %{m | work: %{m.work | force_finalize: true}}
      response = response(tool_calls: [%ToolCall{id: "c1", name: "shell-cmd", arguments: %{}}])

      {:ok, actions, next} = Machine.step(m, {:http_ok, ref, response})

      refute Enum.any?(actions, &match?({:append, {:user, _}}, &1))
      assert {:finalize, :clean} in actions
      assert Enum.any?(actions, &match?({:give_up_replies, :no_reminder}, &1))
      assert next.phase == :idle
      assert next.owed_replies == %{"alice" => 0}
    end

    test "with no debt the turn settles to idle as before" do
      {m, ref} = generating_with_debt([])

      {:ok, actions, next} = Machine.step(m, {:http_ok, ref, response(text: "all done")})

      refute Enum.any?(actions, &match?({:append, {:user, _}}, &1))
      refute Enum.any?(actions, &match?({:give_up_replies, _}, &1))
      assert {:finalize, :clean} in actions
      assert next.phase == :idle
      assert next.owed_replies == %{}
    end

    test "a reply carried across a compaction is reminded, not given up" do
      # intentional: the commit put the carried reply in the active segment, so
      # the turn is not over and the gate gets the same say it gets at any
      # would-be-idle settle. Resting there would give up a debt the agent can
      # still answer — and the reminder is sized against the *committed*
      # messages, which already hold the reply.
      m = owed(committing({:assistant_response, carried(), 0, 10}), ["alice"])

      {:ok, actions, next} = Compaction.resume(m)

      assert [{:append, {:user, reminder}}, :iterate] = actions
      assert next.phase == :generating and next.kind == :chat
      assert next.owed_replies == %{"alice" => 1}
      assert %User{parts: [%Part.Text{text: text}]} = reminder
      assert text =~ "alice"
      Machine.validate!(next)

      # Once the budget is spent the same site rests, and the rest gives the
      # debt up through the funnel.
      spent = Machine.count_reminders(m, ["alice"])
      {:ok, actions, next} = Compaction.resume(spent)

      refute Enum.any?(actions, &match?({:append, {:user, _}}, &1))
      assert Enum.any?(actions, &match?({:give_up_replies, :compaction_carry}, &1))
      assert next.phase == :idle
      Machine.validate!(next)
    end
  end

  describe "the reply-clear event" do
    test "discharges the debt in every non-blocked phase and is ignored when blocked" do
      # intentional: the tool worker may still be running while the turn advances
      # (or after a stop), so a successful send discharges the debt from any live
      # phase — but a blocked agent's turn is over, and the block, not a
      # successful send, owns that debt's disposition.
      for phase <- Machine.phases(), phase not in Machine.blocked_phases() do
        m = %{state_at(phase) | owed_replies: %{"alice" => 0}}

        assert {:ok, [], next} = Machine.step(m, {:reply_sent, "alice"})
        assert next.owed_replies == %{}, "#{phase} must discharge the debt"
        Machine.validate!(next)
      end

      for phase <- Machine.blocked_phases() do
        m = %{state_at(phase) | owed_replies: %{"alice" => 0}}

        assert {:ignore, :blocked, next} = Machine.step(m, {:reply_sent, "alice"})
        assert next.owed_replies == %{"alice" => 0}
      end
    end
  end

  describe "the give-up sites" do
    test "every terminal transition gives up only when a reply is owed" do
      # The §1.6 audit, as a table: each site is driven with a reply owed and
      # with nothing owed, so a site that stops emitting the give-up — or starts
      # emitting it when the machine owes nothing — fails here. The sites and
      # their classifications are listed in `Machine.GiveUp`'s moduledoc.
      for {label, run} <- give_up_sites() do
        assert {:ok, owed, _machine} = run.(["alice"])
        assert Enum.any?(owed, &match?({:give_up_replies, _}, &1)), "#{label}: must give up"

        assert {:ok, plain, _machine} = run.([])
        refute Enum.any?(plain, &match?({:give_up_replies, _}, &1)), "#{label}: owes nothing"
      end
    end

    test "the compaction commit keeps the debt on the machine" do
      # intentional: the commit rewrites the conversation (a new active segment,
      # a reset projection), never the machine — which is why the obligation
      # outlives the conversation segment it was incurred in. The resume that
      # follows the commit owns its disposition (a give-up, when it settles).
      m = owed(committing(nil), ["alice"])

      assert {:ok, _actions, committed} =
               Compaction.commit_compaction(m, response(text: "a summary"))

      assert committed.phase == :committing
      assert Machine.owed_senders(committed) == ["alice"]
      Machine.validate!(committed)
    end
  end

  describe "the resting funnel" do
    test "the give-up is prepended, so it runs before the drain it precedes" do
      # intentional: the executor halts its action list at the first follow-up
      # event, so a `{:drain_inbox}` that ran before the give-up would deliver a
      # queued query, start a turn from it, and the old debt's give-up would
      # never run. `Phase.rest/4` prepends; the stop timer is the site that
      # carries both actions, so the order is pinned there.
      {actions, _resting} = stop_timer_with_queue(["alice"])

      assert index_of(actions, &match?({:give_up_replies, :stopped}, &1)) <
               index_of(actions, &(&1 == {:drain_inbox}))
    end

    test "a query queued during a stop is drained after the old debt is given up" do
      # intentional: the drained query belongs to the *new* turn and gets its own
      # gate — the old debt's give-up was emitted ahead of the drain, and the
      # executor's give-up action discharges it before the drain runs, so the
      # query is delivered to a machine that owes only what it now owes.
      {actions, resting} = stop_timer_with_queue(["alice"])

      assert Enum.any?(actions, &match?({:give_up_replies, :stopped}, &1))

      # What the executor's give-up action does, before it reaches the drain.
      resting = Machine.discharge_all(resting)
      assert Machine.owed_senders(resting) == []

      {:ok, drain_actions, next} =
        Machine.step(resting, {:inbox_drain, [query_entry("bob")], "queued query"})

      assert Enum.any?(drain_actions, &match?({:append, _}, &1))
      assert next.owed_replies == %{"bob" => 0}
      assert Machine.due_senders(next) == ["bob"]
      Machine.validate!(next)
    end
  end

  # --- helpers ---

  # The stop timer's rest with a reply owed *and* a queued entry: its action list
  # carries the give-up and the drain, in that order.
  defp stop_timer_with_queue(senders) do
    m = owed(state_at(:stopping), senders)
    m = %{m | work: %{m.work | ctx: Map.put(m.work.ctx, :inbox_count, 1)}}

    {:ok, actions, next} = Machine.step(m, :stop_timer)
    {actions, next}
  end

  defp query_entry(from) do
    %{
      from: from,
      content: "queued query",
      timestamp: DateTime.utc_now(),
      kind: :query,
      mode: nil
    }
  end

  # `Enum.find_index/2` returns nil for "not found", and every integer is `< nil`
  # in Erlang term order, so an ordering assertion built on it passes vacuously
  # when the action is absent. Flunk instead.
  defp index_of(actions, fun) do
    Enum.find_index(actions, fun) || flunk("no action matching in #{inspect(actions)}")
  end

  # Every site that settles a turn or blocks the agent while it may still owe a
  # reply (issue #31 §1.6), as `{label, (senders -> step result)}`. The sites are
  # grouped by the module that owns them and named one per site, so the table
  # reads as the list of transitions it audits. `Compaction`/`Response` sites
  # return the same `{:ok, actions, machine}` shape `Machine.step/2` does.
  #
  # Five of the audit's 26 sites are deliberately not driven here, because this
  # table drives `Machine.step/2` transitions and these are not reachable as one:
  #
  #   * the `:workspace_notice` + `:cannot_compact` block — it needs a projected
  #     notice that does not fit the reserve (`Transitions`' notice decision, the
  #     `:cannot_compact` arm); the notice's `:fits` and `:needs_compaction` arms
  #     are driven by "a workspace notice" and "a resume that appends a workspace
  #     notice" above;
  #   * the second `:compaction_failed` site — `Compaction.compaction_failed/3`
  #     with an `{:assistant_response, _, _, _}` carried entry, which blocks
  #     instead of resuming; the table drives the carried-entry arm, which
  #     resumes;
  #   * `Turn.quarantine!/2` — it rests outside `Machine.step/2`, because an
  #     undeclared event never reaches the transition table;
  #   * the two `:startup` sites (`Init.NeedsRepair` and `Init.Recovery`) — they
  #     block from `init/1`, before any turn exists.
  #
  # The count is kept honest by `Machine.GiveUp.audit/0`: `GuardTest` checks it
  # against the sources, so a site added or removed without a row fails there
  # rather than going missing here.
  defp give_up_sites, do: turn_sites() ++ compaction_sites() ++ response_sites()

  defp turn_sites do
    [
      {"the stop timer", &stop_timer/1},
      {"the loop breaker", &loop_breaker/1},
      {"an operator-unblocked agent", &unblocked/1},
      {"a blocked entry", &blocked_entry/1},
      {"a stream error", &stream_error/1},
      {"a failed turn", &failed_turn/1},
      {"a killed worker", &killed_worker/1},
      {"an interrupted tool worker", &interrupted_tool/1},
      {"a turn that cannot compact", &cannot_compact/1},
      {"a workspace notice", &workspace_notice/1}
    ]
  end

  defp compaction_sites do
    [
      {"an exhausted reserve with a held message", &reserve_exhausted_held/1},
      {"an exhausted reserve with a queued batch", &reserve_exhausted_queued/1},
      {"an exhausted reserve with nothing held", &reserve_exhausted_empty/1},
      {"an oversized system prompt", &system_oversized/1},
      {"the consecutive-compaction cap", &compaction_loop/1},
      {"a failed compaction", &compaction_failed/1},
      {"a carried reply that rests after a compaction", &resume_carried_reply/1},
      {"a resume with nothing left to resume", &resume_nothing/1},
      {"a resume that appends a workspace notice", &resume_notice/1}
    ]
  end

  defp response_sites do
    [
      {"the settle gate with the budget spent", &settle_gate/1},
      {"an empty assistant reply", &empty_assistant/1}
    ]
  end

  defp stop_timer(senders), do: Machine.step(owed(state_at(:stopping), senders), :stop_timer)

  defp loop_breaker(senders) do
    m = owed(%{state_at(:compaction_loop_detected) | loop_count: 3}, senders)
    Machine.step(m, :loop_ack)
  end

  defp unblocked(senders), do: Machine.step(owed(state_at(:needs_repair), senders), {:unblocked})

  defp blocked_entry(senders) do
    Machine.step(owed(state_at(:generating), senders), {:blocked, :needs_repair, "gone"})
  end

  defp stream_error(senders) do
    m = owed(state_at(:generating), senders)
    Machine.step(m, {:llm_error, m.work.worker_ref, "boom"})
  end

  defp failed_turn(senders) do
    m = owed(state_at(:generating), senders)
    Machine.step(m, {:http_error, m.work.worker_ref, :boom})
  end

  defp killed_worker(senders) do
    Machine.step(worker_machine(senders, :http), {:worker_down, self(), :killed})
  end

  defp interrupted_tool(senders) do
    Machine.step(worker_machine(senders, :tools), {:worker_down, self(), :normal})
  end

  defp workspace_notice(senders) do
    Machine.step(owed(with_notice(state_at(:idle)), senders), :workspace_notice)
  end

  defp cannot_compact(senders) do
    m = owed(with_limit(state_at(:idle), 1), senders)
    Machine.step(m, {:chat_request, {:user_message, user()}})
  end

  defp reserve_exhausted_held(senders) do
    m = %{owed(reserve_state(), senders) | pending_user_message: {:user_message, user()}}
    Compaction.stage(m, nil, nil)
  end

  # The inbox arm blocks instead of resting, because a drain there would re-stage
  # the failing compaction.
  defp reserve_exhausted_queued(senders) do
    m = owed(reserve_state(), senders)
    Compaction.stage(%{m | work: %{m.work | ctx: Map.put(m.work.ctx, :inbox_count, 1)}}, nil, nil)
  end

  defp reserve_exhausted_empty(senders) do
    Compaction.stage(owed(reserve_state(), senders), nil, nil)
  end

  defp system_oversized(senders) do
    Compaction.stage(owed(with_limit(state_at(:idle), 8), senders), nil, nil)
  end

  defp compaction_loop(senders) do
    Compaction.stage(owed(%{state_at(:idle) | loop_count: 3}, senders), nil, nil)
  end

  defp compaction_failed(senders) do
    Compaction.compaction_failed(owed(state_at(:generating), senders), :boom, nil)
  end

  defp resume_carried_reply(senders) do
    # A gate site: the resume reminds while it can, so it gives up only once the
    # budget is spent (the fixture `settle_gate/1` uses).
    m = owed(committing({:assistant_response, carried(), 0, 10}), senders)
    Compaction.resume(Machine.count_reminders(m, Machine.due_senders(m)))
  end

  defp resume_nothing(senders), do: Compaction.resume(owed(committing(nil), senders))

  defp resume_notice(senders) do
    Compaction.resume(owed(with_notice(committing(nil)), senders))
  end

  defp settle_gate(senders) do
    {m, ref} = generating_with_debt(senders)

    Machine.step(
      Machine.count_reminders(m, Machine.due_senders(m)),
      {:http_ok, ref, response(text: "done")}
    )
  end

  defp empty_assistant(senders) do
    {m, ref} = generating_with_debt(senders)
    Machine.step(m, {:http_ok, ref, response(text: "")})
  end

  defp owed(m, senders), do: Machine.owe_replies(m, senders)

  defp with_limit(m, limit),
    do: %{m | work: %{m.work | ctx: %{m.work.ctx | context_limit: limit}}}

  defp with_notice(m), do: %{m | work: %{m.work | pending_notice: "/tmp/AGENTS.md"}}

  defp worker_machine(senders, kind) do
    m = owed(state_at(if(kind == :tools, do: :executing_tools, else: :generating)), senders)
    %{m | work: %{m.work | active_worker: self(), active_worker_kind: kind}}
  end

  defp committing(carried), do: %{state_at(:committing) | entry: {:compaction, [], carried}}

  defp carried, do: elem(Messages.assistant(response(text: "carried")), 1)

  # A machine whose compaction plan cannot even be staged: with no system
  # message and no vocation, `Dispatch.compaction_plan/1` reports
  # `{:error, :reserve_exhausted}`.
  defp reserve_state do
    m = state_at(:idle)
    %{m | work: %{m.work | ctx: %{m.work.ctx | messages: []}}}
  end

  defp user do
    %User{index: nil, parts: [%Part.Text{text: "hi"}], api_logs: []}
  end

  defp generating_with_debt(senders) do
    ref = make_ref()
    m = state_at(:generating)
    {Machine.owe_replies(%{m | work: %{m.work | worker_ref: ref}}, senders), ref}
  end

  defp reminder_text(actions) do
    case Enum.filter(actions, &match?({:append, {:user, _}}, &1)) do
      [{:append, {:user, %User{parts: [%Part.Text{text: text}]}}}] -> text
      [] -> nil
    end
  end

  # The window between "the reply fits the content budget" and "the reminder
  # fits too" is a few tokens wide; derive the limit from the same estimator the
  # gate uses and assert the precondition, so a moved reserve floor fails loudly
  # here instead of surfacing as an unrelated phase assertion.
  defp tight_limit(projected) do
    limit = Budget.size(projected) + 8_192 + 5

    assert Budget.fits?(projected, limit),
           "the fixture must leave the reply inside the content budget"

    assert Budget.remaining(projected, limit) < 40,
           "the fixture must leave less room than the reminder needs"

    limit
  end

  # The `{:assistant, %Assistant{}}` tuple `Response.assistant_with_log/2`
  # builds, so the projected list the fixture sizes is the list the gate sizes.
  defp assistant_message(response), do: Messages.assistant(response)

  defp response(overrides) do
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

  defp kind_for(:committing), do: :compaction
  defp kind_for(_), do: :chat

  defp worker_kind_for(:generating), do: :http
  defp worker_kind_for(:executing_tools), do: :tools
  defp worker_kind_for(_), do: nil

  defp ref_for(p) when p in [:generating, :executing_tools, :stopping], do: make_ref()
  defp ref_for(_), do: nil

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

  defp system_message do
    {:system,
     %Nest.Messages.System{
       index: 0,
       parts: [%Part.Text{text: "sys"}],
       api_logs: []
     }}
  end
end
