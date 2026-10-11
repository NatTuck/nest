defmodule Nest.Agents.Agent.MachineBackgroundedTest do
  @moduledoc """
  Late-result and worker-death routing for a backgrounded batch (issue #36,
  step 2).

  A batch moved to the background has no live worker: its result arrives
  keyed on `work.backgrounded`, and its worker's `:DOWN` would otherwise
  fall through to `:unknown_worker_down`. Both are delivered once, as a
  runtime `:notice`, and the entry is cleared.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Repair
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Agent.Turn.Executor
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User

  describe "a backgrounded batch's late result" do
    test "is delivered exactly once as a :notice and clears the entry" do
      ref = make_ref()
      machine = backgrounded_machine(%{ref => %{pid: self(), ids: ["c1"]}})

      {:ok, state} = Turn.settle(state(machine), {:tool_results, ref, [result("done")]})

      assert [%{kind: :notice, content: content}] = state.live.inbox
      assert content =~ "finished"
      assert content =~ "done"
      assert state.live.machine.work.backgrounded == %{}

      # The entry is gone, so a duplicate delivery for the same ref is
      # stale-dropped: the ref answered exactly once.
      {:ok, again} = Turn.settle(state, {:tool_results, ref, [result("again")]})
      assert [%{kind: :notice, content: ^content}] = again.live.inbox
    end

    test "a timed-out command's result is worded as a timeout, not a finish" do
      ref = make_ref()
      machine = backgrounded_machine(%{ref => %{pid: self(), ids: ["c1"]}})
      timed_out = result("partial output\n\n[stderr]\n[Command timed out after 60000ms]")

      {:ok, state} = Turn.settle(state(machine), {:tool_results, ref, [timed_out]})

      assert [%{kind: :notice, content: content}] = state.live.inbox
      assert content =~ "timed out"
      refute content =~ "finished"
    end

    test "lands while a *new* batch is in flight, with a live worker_ref" do
      ref = make_ref()
      live = make_ref()

      machine =
        backgrounded_machine(%{ref => %{pid: self(), ids: ["c1"]}},
          phase: :generating,
          worker: {:http, live}
        )

      {:ok, state} = Turn.settle(state(machine), {:tool_results, ref, [result("late")]})

      assert [%{kind: :notice, content: content}] = state.live.inbox
      assert content =~ "late"

      # Routing keys on the entry, not on `worker_ref` being nil: the live
      # worker's own ref survives, and the backgrounded entry is gone so its
      # ref answers exactly once.
      assert state.live.machine.work.worker_ref == live
      assert state.live.machine.work.backgrounded == %{}
    end
  end

  describe "a backgrounded worker's death" do
    test "produces a notice and clears the entry" do
      ref = make_ref()
      pid = self()
      machine = backgrounded_machine(%{ref => %{pid: pid, ids: ["c1"]}})

      {:ok, state} = Turn.settle(state(machine), {:worker_down, pid, :killed})

      assert [%{kind: :notice, content: content}] = state.live.inbox
      assert content =~ "stopped before it finished"
      assert content =~ ":killed"
      assert state.live.machine.work.backgrounded == %{}
    end

    test "a different pid's :DOWN does not resolve the entry" do
      ref = make_ref()
      machine = backgrounded_machine(%{ref => %{pid: self(), ids: ["c1"]}})

      {:ok, state} = Turn.settle(state(machine), {:worker_down, spawn(fn -> :ok end), :killed})

      # Only the entry's own pid resolves it; any other death is
      # `:unknown_worker_down`, which leaves the entry (and its promise) intact.
      assert state.live.inbox == []
      assert Map.has_key?(state.live.machine.work.backgrounded, ref)
    end

    test "every entry a dead pid owns is resolved, so none leaks" do
      refs = [make_ref(), make_ref()]

      backgrounded = Map.new(refs, &{&1, %{pid: self(), ids: ["c1"]}})
      machine = backgrounded_machine(backgrounded)

      {:ok, state} = Turn.settle(state(machine), {:worker_down, self(), :killed})

      # Two entries can share a pid, so resolving only the first would leave
      # the other's promise dangling forever.
      assert [%{kind: :notice}, %{kind: :notice}] = state.live.inbox
      assert state.live.machine.work.backgrounded == %{}
    end

    test "is resolved during a compaction window, not swallowed" do
      ref = make_ref()

      # `Compaction.stage/3` keeps `work`, so a backgrounded worker can die
      # while the compactor is in flight. The `:compaction` arm would answer
      # `:unknown_worker_down` — no notice, and the entry leaks for good.
      machine =
        backgrounded_machine(%{ref => %{pid: self(), ids: ["c1"]}},
          phase: :generating,
          kind: :compaction,
          worker: {:http, make_ref()}
        )

      {:ok, state} = Turn.settle(state(machine), {:worker_down, self(), :killed})

      assert [%{kind: :notice, content: content}] = state.live.inbox
      assert content =~ "stopped before it finished"
      assert state.live.machine.work.backgrounded == %{}
    end
  end

  describe "a blocked phase" do
    test "resolves a backgrounded pid, and keeps :blocked precedence for any other" do
      # `Phase.enter_blocked/2` clears only `worker_kind`, so a compaction that
      # blocked on `:compaction_failed` still holds its worker's pid. The
      # backgrounded clause sits above the blocked catch-all — it has to, or the
      # pid that moved out of `active_worker` would have nowhere to be resolved —
      # so its non-backgrounded arm restores that precedence by hand: otherwise
      # the worker's `:normal` `:DOWN` re-runs `compaction_failed/3` and
      # broadcasts a second `{:compaction_error}` for a failure the block has
      # already reported.
      blocked = blocked_machine()

      assert {:ignore, :blocked, ^blocked} =
               Machine.step(blocked, {:worker_down, self(), :normal})

      # A pid the entry *does* own is still resolved, whatever the phase: the
      # batch's promise is answered even though the turn is blocked.
      ref = make_ref()
      with_batch = blocked_machine(%{ref => %{pid: self(), ids: ["c1"]}})

      assert {:ok, [delivery], resolved} =
               Machine.step(with_batch, {:worker_down, self(), :normal})

      # The death names the calls it closes: the entry is the only place those
      # ids exist (a result names its own).
      assert {:deliver_backgrounded, ^ref, {:worker_down, :normal}, ["c1"]} = delivery
      assert resolved.work.backgrounded == %{}
    end
  end

  describe "an already-idle machine" do
    test "drains the notice, so an outcome that arrives after the turn ended is delivered" do
      # The turn that backgrounded the batch has ended, so nothing else would
      # ever wake the agent: `{:deliver_backgrounded, …}` only *enqueues* the
      # notice, and the `{:drain_inbox}` is what starts its own turn. Both
      # outcomes a backgrounded batch can produce need it — its result and its
      # worker's death — or the notice would sit in the queue forever and an
      # `agents-wait` would resolve with the pre-result answer.
      ref = make_ref()

      machine =
        backgrounded_machine(%{ref => %{pid: self(), ids: ["c1"]}},
          phase: :idle,
          worker: {nil, nil}
        )

      results = [result("done")]

      assert {:ok, actions, next} = Machine.step(machine, {:tool_results, ref, results})

      assert actions == [
               {:deliver_backgrounded, ref, {:results, results}, ["c1"]},
               {:drain_inbox}
             ]

      assert next.work.backgrounded == %{}

      death = make_ref()

      dying =
        backgrounded_machine(%{death => %{pid: self(), ids: ["c1"]}},
          phase: :idle,
          worker: {nil, nil}
        )

      assert {:ok, death_actions, dead} = Machine.step(dying, {:worker_down, self(), :killed})

      assert death_actions == [
               {:deliver_backgrounded, death, {:worker_down, :killed}, ["c1"]},
               {:drain_inbox}
             ]

      assert dead.work.backgrounded == %{}
    end
  end

  describe "a stopped turn" do
    test "drops a backgrounded result and a backgrounded death" do
      ref = make_ref()

      stopping =
        backgrounded_machine(%{ref => %{pid: self(), ids: ["c1"]}},
          phase: :stopping,
          worker: {nil, make_ref()}
        )

      # The stop path records its own cancellation notice (step 4), so
      # delivering a backgrounded result here as well would report the same
      # call twice: the stop guard must win over the backgrounded clauses.
      assert {:ignore, :late_result_after_stop, ^stopping} =
               Machine.step(stopping, {:tool_results, ref, [result("late")]})

      assert {:ignore, :late_worker_down, ^stopping} =
               Machine.step(stopping, {:worker_down, self(), :killed})
    end

    test "kills every backgrounded worker, clears the entries and records the cancellation" do
      # A backgrounded batch's worker is no longer `active_worker`, so a stop
      # that killed only that one would leave the batch running to its own bound
      # with its promise unkept and its entry leaking forever. The kill list is
      # built from `backgrounded` *before* the map is cleared, one kill per
      # distinct pid (two entries can share one) in a deterministic order: the
      # map's iteration order is arbitrary, and these are ordered actions.
      first =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      second =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      backgrounded = %{
        make_ref() => %{pid: first, ids: ["c1", "c2"]},
        make_ref() => %{pid: second, ids: ["c3"]},
        make_ref() => %{pid: first, ids: ["c4", "c5", "c6"]}
      }

      machine = backgrounded_machine(backgrounded)

      assert {:ok, actions, stopping} = Machine.step(machine, {:stop, self()})

      expected = Enum.map(Enum.sort([first, second]), &{:kill, &1})
      assert Enum.filter(actions, &match?({:kill, _}, &1)) == expected

      # The *order* is load-bearing, not just the set: the backgrounded kills come
      # before `{:stop_all_children}` (which clears the child map the coordinator
      # kills were read from) and before the `{:arm_timer, …}` that owns the
      # terminal transition — the arm is the stop's last action, and the executor
      # halts the action list on its follow event, so anything after it would
      # never run. The fixture has no coordinators, no timer and no active
      # worker, so those slots are empty.
      assert Enum.map(actions, &elem(&1, 0)) == [
               :ack,
               :set_cancelled,
               :kill,
               :kill,
               :stop_all_children,
               :append_many,
               :arm_timer
             ]

      assert stopping.phase == :stopping
      assert stopping.work.backgrounded == %{}
      assert Enum.any?(actions, &match?({:arm_timer, _, :stop_timer}, &1))
      Machine.validate!(stopping)

      # One cancellation record for the whole stop: a `backgrounded` entry
      # carries no call identity, so per-entry records would repeat the same
      # words — and two collapsed records would be two consecutive assistant
      # messages, which the wire rejects. The count is what tells the model how
      # many promises the stop voided, and it counts the *calls*: three entries
      # carrying 2, 1 and 3 calls voided six promises, so a count of the entries
      # (or of the two distinct pids) would understate it.
      assert [{:append_many, record}] = Enum.filter(actions, &match?({:append_many, _}, &1))

      assert [
               {:user, %User{parts: [%Part.Text{text: notice}]}},
               {:assistant, %Assistant{parts: [%Part.Text{text: ack}]}}
             ] = record

      assert notice =~ "6 tool calls"
      assert notice =~ "cancelled when the conversation was stopped"
      assert ack =~ "will not wait"

      Process.exit(first, :kill)
      Process.exit(second, :kill)
    end

    test "re-arms the timer when the cancellation record is refused" do
      # The refusal halts the action list before the stop's own `{:arm_timer, …}`
      # runs, and the timer owns the single terminal transition: without it the
      # turn would sit in `:stopping` forever. The record cannot land, so the
      # warning is its only trace.
      machine = backgrounded_machine(%{make_ref() => %{pid: self(), ids: ["c1"]}})
      assert {:ok, _actions, stopping} = Machine.step(machine, {:stop, self()})

      assert {:ok, actions, ^stopping} =
               Machine.step(stopping, {:append_result, :invalid, "over the limit"})

      assert [{:log, :warning, message}, {:arm_timer, _, :stop_timer}] = actions
      assert message =~ "over the limit"
    end
  end

  describe "a death's fulfilled ids" do
    test "close the promise, so a load records no second loss" do
      # A killed batch can never report a result, so the death notice closes its
      # promise — and the ids it names come from the entry, since there is no
      # result to name them from. Without them the notice's message carries no
      # fulfilled marker and a later load appends a second record ("lost when
      # this agent restarted") for a promise the death already closed.
      ref = make_ref()

      machine =
        backgrounded_machine(
          %{ref => %{pid: self(), ids: ["call_1"]}},
          phase: :idle,
          worker: {nil, nil}
        )

      assert {:ok, actions, dead} = Machine.step(machine, {:worker_down, self(), :killed})

      assert actions == [
               {:deliver_backgrounded, ref, {:worker_down, :killed}, ["call_1"]},
               {:drain_inbox}
             ]

      assert dead.work.backgrounded == %{}

      # The notice entry carries them, and the message the drain builds from it
      # is the marker's only writer (`Inbox.build_drained_message/3`).
      agent = %{
        state(machine)
        | chat_state: %{state(machine).chat_state | messages: promised_tail()}
      }

      {_agent, {:inbox_drain, [entry], content}} = Executor.run_all(actions, agent)

      assert %{kind: :notice, fulfilled_ids: ["call_1"]} = entry

      notice = Inbox.build_drained_message([entry], content, "chat")
      loaded = promised_tail() ++ [notice]

      # The promise the death closed is not reported — without the marker it is
      # (the baseline assertion below), and a restart would append a record for a
      # call whose outcome is already in the transcript. The notice's own user
      # tail is a different heal: `{:bridge, …}`, the idle-agent rule.
      assert {:lost_promises, _} = Repair.classify_load(promised_tail())
      assert [] = MessageList.backgrounded_results(loaded)
      assert {:bridge, _} = Repair.classify_load(loaded)
    end
  end

  describe "an unknown ref" do
    test "is still stale-dropped with no notice" do
      machine =
        Machine.new(
          phase: :executing_tools,
          kind: :chat,
          work: %Machine.Work{worker_kind: :tools, worker_ref: make_ref()}
        )

      {:ok, state} = Turn.settle(state(machine), {:tool_results, make_ref(), [result("x")]})

      assert state.live.inbox == []
      assert state.live.machine.work.backgrounded == %{}
    end
  end

  # --- helpers ---

  # A machine holding `backgrounded` (`%{ref => %{pid: pid, ids: ids}}`), in
  # `opts`' phase/kind. Defaults to `:executing_tools`/`:chat` with a `:tools`
  # worker_kind and no `worker_ref`; tests override what they pin.
  defp backgrounded_machine(backgrounded, opts \\ []) do
    {worker_kind, worker_ref} = Keyword.get(opts, :worker, {:tools, nil})

    Machine.new(
      phase: Keyword.get(opts, :phase, :executing_tools),
      kind: Keyword.get(opts, :kind, :chat),
      work: %Machine.Work{
        worker_kind: worker_kind,
        worker_ref: worker_ref,
        backgrounded: backgrounded
      }
    )
  end

  defp result(content) do
    %ToolResult{
      tool_call_id: "c1",
      name: "shell-cmd",
      arguments: %{},
      content: content,
      is_error: false
    }
  end

  # A blocked machine (a failed compaction) that still holds its worker's pid:
  # `Phase.enter_blocked/2` clears `worker_kind` but leaves `active_worker`.
  defp blocked_machine(backgrounded \\ %{}) do
    machine =
      backgrounded_machine(backgrounded,
        phase: :compaction_failed,
        kind: :compaction,
        worker: {nil, nil}
      )

    %{machine | work: %{machine.work | active_worker: self()}}
  end

  defp state(machine) do
    %Agent{
      name: "bg-test",
      space_id: 1,
      llm_metrics: %Agent.LlmMetrics{
        context_limit: 100_000,
        context_limit_source: :config,
        usage_totals: Broadcasts.empty_usage_totals(),
        descendant_usage: Broadcasts.empty_usage_totals()
      },
      chat_state: %Agent.ChatState{messages: [system(0)], next_message_index: 1},
      live: %Agent.ChatState.Live{machine: machine}
    }
  end

  # The transcript a backgrounded batch leaves behind: the call it answered and
  # the synthetic result that promised a message, on a valid wire sequence.
  defp promised_tail do
    [
      system(0),
      {:user, %User{index: 1, parts: [%Part.Text{text: "hi"}]}},
      {:assistant,
       %Assistant{
         index: 2,
         parts: [%Part.ToolUse{id: "call_1", name: "shell-cmd", arguments: %{}}],
         api_logs: []
       }},
      {:tool,
       %Tool{
         index: 3,
         parts: [
           %Part.ToolResult{
             tool_call_id: "call_1",
             name: "shell-cmd",
             arguments: %{},
             content: "The shell-cmd call was moved to the background.",
             is_error: false,
             state: "backgrounded"
           }
         ],
         api_logs: []
       }},
      {:assistant, %Assistant{index: 4, parts: [%Part.Text{text: "ok"}], api_logs: []}}
    ]
  end

  defp system(index) do
    {:system,
     %Nest.Messages.System{
       index: index,
       parts: [%Nest.Messages.Part.Text{text: "sys"}],
       api_logs: []
     }}
  end
end
