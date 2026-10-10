defmodule Nest.Agents.Agent.Turn.ExecutorTest do
  @moduledoc false
  # One focused assertion per executor action (plus fact round-trips). The
  # guard suite pins that every declared action has a clause.

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Agents.Agent.Turn.Executor
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Tokens.ConversationSize

  defp state do
    %Agent{
      name: "exec-#{System.unique_integer([:positive])}",
      space_id: 1,
      model: %{name: "m"},
      client_config: %Nest.LLM.ClientConfig{client: Nest.LLM.MockClient, model: "m"},
      llm_metrics: %Agent.LlmMetrics{
        context_limit: 100_000,
        context_limit_source: :config,
        usage_totals: Broadcasts.empty_usage_totals(),
        descendant_usage: Broadcasts.empty_usage_totals()
      },
      live: %Agent.ChatState.Live{
        machine: %Machine{work: %Machine.Work{ctx: ctx()}}
      },
      vocation: vocation()
    }
  end

  # A vocation defining the modes the drain tests request, so
  # `ChatPipeline.resolve_mode_and_caps/4` resolves "plan" to "plan" and an
  # unknown mode to the "chat" default.
  defp vocation do
    %Nest.Vocations.Vocation{
      modes: %{
        "chat" => %{"caps" => %{}},
        "plan" => %{"caps" => %{}},
        "review" => %{"caps" => %{}}
      }
    }
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
      messages: [],
      tmp_path: nil,
      workspace_path: nil,
      mode: "chat",
      next_message_index: 0,
      crossed_thresholds: %MapSet{},
      context_projection: nil,
      api_log_sequences: %{},
      vocation: nil,
      depth: 0
    }
  end

  defp user_msg do
    {:user,
     %User{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: "hi"}],
       api_logs: []
     }}
  end

  defp assistant_msg do
    {:assistant,
     %Assistant{
       index: nil,
       timestamp: DateTime.utc_now(),
       parts: [%Part.Text{text: "ok"}],
       api_logs: []
     }}
  end

  defp run(action, state \\ state()), do: Executor.run_all(List.wrap(action), state)

  # The same state with a child registered against `target`.
  defp with_target(state, target) do
    {:ok, [], machine} =
      Machine.step(state.live.machine, {:child_spawned, "kid", false, target})

    %{state | live: %{state.live | machine: machine}}
  end

  defp inbox_state(entries, mode, base \\ nil) do
    base = base || state()
    %{base | live: %{base.live | inbox: entries, mode: mode}}
  end

  defp entry(kind, from, content, mode \\ nil) do
    %{from: from, content: content, timestamp: DateTime.utc_now(), kind: kind, mode: mode}
  end

  defp system_msg do
    {:system, %Nest.Messages.System{index: 0, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  describe "bookkeeping actions" do
    test "merge_metrics folds usage into the totals" do
      {state, nil} = run({:merge_metrics, %{output_tokens: 7, total_tokens: 9}})
      assert state.llm_metrics.usage_totals.output_tokens == 7
    end

    test "set_crossed_thresholds / set_context_projection / set_api_log_sequences" do
      {state, nil} = run({:set_crossed_thresholds, MapSet.new([:p25])})
      assert state.live.crossed_thresholds == MapSet.new([:p25])

      {state, nil} = run({:set_context_projection, 42}, state)
      assert state.live.context_projection == 42

      {state, nil} = run({:set_context_projection, "nope"}, state)
      assert state.live.context_projection == 42

      {state, nil} = run({:set_api_log_sequences, %{0 => 3}}, state)
      assert state.live.api_log_sequences == %{0 => 3}
    end

    test "set_cancelled sets the sticky flag" do
      {state, nil} = run({:set_cancelled, true})
      assert state.live.cancelled
    end

    test "set_streaming seeds an accumulator at the index" do
      {state, nil} = run({:set_streaming, 5})
      assert state.live.streaming_acc.index == 5
    end

    test "ack sends a term" do
      {_state, nil} = run({:ack, self(), :stopped})
      assert_received :stopped
    end

    test "kill exits the worker" do
      pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(pid)
      {_state, nil} = run({:kill, pid})
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500
    end

    test "cancel_timer is a no-op for unknown refs" do
      assert {_state, nil} = run({:cancel_timer, make_ref()})
    end

    test "arm_timer produces a timer_armed follow-up" do
      {_state, follow} = run({:arm_timer, 5_000, :stop_timer})
      assert {:timer_armed, :stop_timer, ref} = follow
      Process.cancel_timer(ref)
    end

    test "log emits at the given level" do
      assert capture_log(fn -> {_state, nil} = run({:log, :warning, "noop"}) end) =~ "noop"
    end

    test "iterate is deferred through the mailbox" do
      assert {_state, nil} = run(:iterate)
      assert_received :iterate
    end
  end

  describe "sequence actions" do
    test "append and append_many persist and round-trip ok" do
      capture_log(fn ->
        {appended, nil} = run({:append, user_msg()})
        assert [{:user, %{index: 0}}] = appended.chat_state.messages

        {batch, nil} = run({:append_many, [user_msg()]}, appended)

        # The terminal boundary bridges the double user role.
        assert Enum.map(batch.chat_state.messages, &elem(&1, 0)) == [:user, :assistant, :user]
      end)
    end

    test "append result rides back on failure on the live path" do
      capture_log(fn ->
        live =
          put_in(
            state().live.machine,
            Machine.status_to_machine(state().live.machine, :streaming)
          )

        # Seed an assistant tail: the next assistant append is still a
        # genuinely broken live sequence. (Only user-after-user is
        # bridged on the live path; assistant-after-assistant fails
        # loudly.)
        {seeded, nil} = run({:append, assistant_msg()}, live)

        assert {_state, {:append_result, :invalid, reason}} =
                 run({:append, assistant_msg()}, seeded)

        assert reason =~ "second consecutive assistant"
      end)
    end

    test "record_file_access is a no-op with no messages" do
      assert {_state, nil} = run({:record_file_access})
    end
  end

  describe "fact round-trips" do
    test "preflight returns a preflight_result" do
      {_state, {:preflight_result, decision}} = run({:preflight, ctx(), [], :cont})
      assert decision == :fits
    end

    test "spawn_http returns worker_started and monitors a task" do
      {_state, follow} = run({:spawn_http, Map.put(ctx(), :messages, [])})
      assert {:worker_started, ref, pid, :http} = follow
      assert is_reference(ref) and is_pid(pid)
      Process.exit(pid, :kill)
    end

    test "spawn_tools returns worker_started" do
      {_state, follow} = run({:spawn_tools, ctx(), []})
      assert {:worker_started, _ref, pid, :tools} = follow
      Process.exit(pid, :kill)
    end
  end

  describe "broadcasts and terminal actions" do
    test "broadcast :status" do
      state = state()
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")
      {_state, nil} = run({:broadcast, :status, nil}, state)
      assert_receive {:chat_status, _}
    end

    test "broadcast overflow emits chat:error" do
      state = state()
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      capture_log(fn ->
        {_state, nil} = run({:broadcast, {:overflow, :reserve_exhausted, "compact"}, nil}, state)
      end)

      assert_receive {:chat_error, _}
    end

    test "finalize clean completes a turn" do
      assert {_state, nil} = run({:finalize, :clean})
    end

    test "finalize stopped recovery appends nothing without a partial" do
      assert {_state, nil} = run({:finalize, %{"stopped_by_user" => true}})
    end

    test "fail_turn broadcasts chat:error" do
      state = state()
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      capture_log(fn ->
        {_state, nil} = run({:fail_turn, %RuntimeError{message: "boom"}, []}, state)
      end)

      assert_receive {:chat_error, %{content: content}}
      assert content =~ "boom"
    end

    test "llm_error appends an error assistant" do
      state = state()
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      captured =
        capture_log(fn ->
          {state, nil} = run({:llm_error, "gone"}, state)
          send(self(), {:appended, state})
        end)

      assert captured =~ "gone"
      assert_receive {:appended, state}
      assert [{:assistant, %{metadata: %{"error" => true}}}] = state.chat_state.messages
    end

    test "child_message delivers to the child's reporting target, or to the inbox" do
      # No target (a plain spawn): the parent's own inbox.
      {state, nil} = run({:child_message, "kid", {:ok, "resp"}})
      assert [%{from: "kid", content: "resp", kind: :agent}] = state.live.inbox

      # A live target (a batch coordinator): the outcome is sent, not enqueued.
      {live, nil} = run({:child_message, "kid", {:ok, "resp"}}, with_target(state(), self()))
      assert_received {:child_message, "kid", {:ok, "resp"}}
      assert live.live.inbox == []

      # A dead target: the fallback, so a crashed coordinator degrades to
      # per-child messages instead of silence.
      dead = spawn(fn -> :ok end)
      dead_ref = Process.monitor(dead)
      assert_receive {:DOWN, ^dead_ref, :process, ^dead, _reason}

      {fallback, nil} = run({:child_message, "kid", {:ok, "resp"}}, with_target(state(), dead))
      assert [%{from: "kid", content: "resp", kind: :agent}] = fallback.live.inbox
    end

    test "merge_usage folds descendant usage" do
      {state, nil} = run({:merge_usage, "kid", %{output_tokens: 4}})
      assert state.llm_metrics.descendant_usage.output_tokens == 4
    end

    test "drain_inbox peeks: the queue is untouched and no inbox frame is sent" do
      # intentional: peek-then-consume (#26). The drain computes the batch's
      # content and applies its mode, but leaves `state.live.inbox` alone and
      # broadcasts nothing: the machine decides what to do with the content and
      # `{:consume_inbox, _}` is what clears the queue. A delivery that cannot
      # proceed (a compaction, a block) therefore leaves the message queued and
      # visible instead of in no payload at all.
      peer = entry(:agent, "peer", "peer note")
      state = inbox_state([peer], "chat")
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      {state, {:inbox_drain, [^peer], content}} = run({:drain_inbox}, state)

      assert content == "[Message from agent \"peer\"]\npeer note"
      assert state.live.inbox == [peer]
      refute_receive {:chat_inbox, _}, 50
    end

    test "consume_inbox clears exactly the peeked batch and sends one frame per consume" do
      # intentional: the consume half is emitted by the branch that actually
      # appended the message, and it clears only the batch the peek delivered —
      # anything the peek did not take stays queued and stays on the wire. One
      # consume is one `chat:inbox` frame, carrying the remaining queue.
      peer = entry(:agent, "peer", "peer note")
      alice = entry(:user, "alice", "human note", "plan")
      state = inbox_state([peer, alice], "chat")
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      {state, nil} = run({:consume_inbox, [peer]}, state)

      assert state.live.inbox == [alice]

      assert_receive {:chat_inbox, %{count: 1, messages: [%{"content" => "human note"}]}}
      refute_receive {:chat_inbox, _}, 50

      # The batch was the whole queue: the frame reports an empty inbox.
      {state, nil} = run({:consume_inbox, [alice]}, state)

      assert state.live.inbox == []
      assert_receive {:chat_inbox, %{count: 0, messages: []}}
      refute_receive {:chat_inbox, _}, 50
    end

    test "drain_inbox :append appends the batch and consumes it without a preflight" do
      # intentional: the loop breaker's give-up shape (#26). The executor builds
      # the message from the peeked batch and appends it directly — no
      # `start_chat/3`, so the ack cannot re-enter the compaction decision it
      # just gave up on — then consumes exactly the batch it appended.
      peer = entry(:agent, "peer", "peer note")
      state = inbox_state([peer], "chat")
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      # The fixture agent has no DB row, so the persist step warns; capturing it
      # keeps the suite's console clean and pins that the append really went
      # through `MessageAppender` rather than around it.
      log =
        capture_log(fn ->
          {state, nil} = run({:drain_inbox, :append}, state)
          send(self(), {:appended, state})
        end)

      assert log =~ "Failed to persist message"
      assert_receive {:appended, state}

      assert state.live.inbox == []

      assert [
               {:user,
                %User{
                  parts: [
                    %Part.Text{text: "[mode: chat]\n[Message from agent \"peer\"]\npeer note"}
                  ]
                }}
             ] = state.chat_state.messages

      assert_receive {:chat_inbox, %{count: 0, messages: []}}
      refute_receive {:chat_inbox, _}, 50
    end

    test "drain_inbox is a no-op on an empty inbox" do
      assert {_state, nil} = run({:drain_inbox})
      assert {_state, nil} = run({:drain_inbox, :append})
      assert {_state, nil} = run({:consume_inbox, []})
    end

    test "drain_inbox applies the batch's human mode and otherwise leaves the mode alone" do
      # intentional: one mode per delivered batch, chosen by `Inbox.drain_mode/1`
      # and applied at the peek (never at enqueue time, where it would
      # re-resolve the ongoing turn's caps). The batch is the queue's head — an
      # agent run, or a lone human message — so a human entry behind an agent
      # run is not part of this delivery at all.
      peer = entry(:agent, "peer", "peer note")
      human = entry(:user, "alice", "human note", "plan")

      # An agent-run head is delivered under the agent's current mode; the peek
      # consumes nothing, so the queue is untouched (including the human entry
      # behind the batch).
      {state, {:inbox_drain, [^peer], content}} =
        run({:drain_inbox}, inbox_state([peer, human], "chat"))

      assert state.live.inbox == [peer, human]
      assert state.live.mode == "chat"
      assert content == "[Message from agent \"peer\"]\npeer note"

      # A lone human message runs in its own mode, and its text is bare: a
      # queued human message must read like one typed while the agent was idle
      # (issue #31 decision 8).
      {state, {:inbox_drain, [^human], content}} =
        run({:drain_inbox}, inbox_state([human], "chat"))

      assert state.live.inbox == [human]
      assert state.live.mode == "plan"
      assert content == "human note"

      # A mode the vocation does not define resolves to its default, exactly
      # as an idle chat's request would, so `currentMode` never holds a mode
      # the vocation does not define.
      bogus = %{human | mode: "bogus"}

      {state, {:inbox_drain, [^bogus], _content}} =
        run({:drain_inbox}, inbox_state([bogus], "chat"))

      assert state.live.mode == "chat"
    end

    test "Turn.drain_inbox/1 reports :queued when the delivery parks for a compaction" do
      # intentional: under peek-then-consume the executor leaves the queue
      # alone, so "the inbox is empty" no longer means "delivered". A drain
      # whose delivery parked — here a compaction it needed before it could
      # fit — still holds the message, so the reply to `handle_delivery/3` is
      # `:queued`, not the `:delivered` the consume-first design reported.
      messages = [system_msg(), user_msg(), assistant_msg(), user_msg()]
      base = state()

      content = "[Message from agent \"peer\"]\npeer note"
      projected = messages ++ [Dispatch.build_user_message(content, "chat")]
      limit = ConversationSize.size(projected) + 8_191

      state = %{
        base
        | chat_state: %{base.chat_state | messages: messages},
          llm_metrics: %{base.llm_metrics | context_limit: limit}
      }

      assert Dispatch.preflight_decision(projected, limit) == :needs_compaction,
             "the fixture must force the :needs_compaction branch"

      peer = entry(:agent, "peer", "peer note")
      state = inbox_state([peer], "chat", state)

      {state, :queued} = Turn.drain_inbox(state)

      assert state.live.inbox == [peer]
      assert state.live.machine.kind == :compaction
      assert state.live.machine.pending_user_message == nil
    end

    test "stop_all_children clears the children sub-machine" do
      {state, nil} = run({:stop_all_children})
      assert state.live.machine.children.children == %{}
    end

    test "stop_child / archive_child tolerate unknown names" do
      capture_log(fn ->
        assert {_state, nil} = run({:stop_child, "missing"})
        assert {_state, nil} = run({:archive_child, "missing"})
      end)
    end

    test "commit_compaction with an empty summary returns commit_error" do
      data = %{
        summary_text: "",
        staged: [],
        summary_assistant: {:assistant, %Nest.Messages.Assistant{parts: [], api_logs: []}},
        carried_entry: nil
      }

      assert {_state, {:commit_error, _reason}} = run({:commit_compaction, data})
    end

    test "notification / error / compaction broadcasts" do
      state = state()
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      {_state, nil} = run({:broadcast, {:notification, %{type: "x"}}, nil}, state)
      assert_receive {:chat_notification, %{type: "x"}}

      capture_log(fn ->
        {_state, nil} = run({:broadcast, {:error, 0, "oops"}, nil}, state)
        {_state, nil} = run({:broadcast, {:compaction_error, "nope"}, nil}, state)
        {_state, nil} = run({:broadcast, {:compaction_loop, "loop", 3, 3}, nil}, state)
      end)

      assert_receive {:chat_error, %{content: "oops"}}
      assert_receive {:chat_error, %{compactionError: true}}
    end

    test "stage_compaction spawns the compactor worker" do
      {_state, follow} = run({:stage_compaction, ctx()})
      assert {:worker_started, _ref, pid, :http} = follow
      Process.exit(pid, :kill)
    end

    test "fail_turn formats a stacktrace snippet" do
      capture_log(fn ->
        {_state, nil} =
          run({:fail_turn, %RuntimeError{message: "boom"}, [{__MODULE__, :test, 1, []}]}, state())
      end)
    end
  end

  describe "give-up paths through the settle loop" do
    test "a refused append on the loop ack's drain leaves the batch queued and fails loudly" do
      # intentional: `{:drain_inbox, :append}` must never consume a batch it
      # did not append — that would be the "in neither the queue nor the
      # transcript" state #26 exists to eliminate. Driven through the real
      # settle loop with a context limit that refuses every append, so the
      # appender's `:invalid` refusal is the branch the path actually hits.
      base = state()
      peer = entry(:agent, "peer", "peer note")

      state = inbox_state([peer], "chat", base)
      state = %{state | llm_metrics: %{base.llm_metrics | context_limit: 1}}

      machine = %{state.live.machine | phase: :compaction_loop_detected, loop_count: 3}
      state = %{state | live: %{state.live | machine: machine}}

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      {result, log} = with_log(fn -> Turn.settle(state, :loop_ack) end)

      assert {:ok, settled} = result

      # Nothing consumed the batch: it is still queued, and no `chat:inbox`
      # frame was emitted at all (a consume is the only thing that sends one),
      # while the status payload keeps the queue visible to a client.
      assert settled.live.inbox == [peer]
      refute_receive {:chat_inbox, _}, 50
      assert_receive {:chat_status, %{status: "context_overflow", pendingMessageCount: 1}}

      # And the refusal is visible: the turn fails with `chat:error` rather
      # than dropping the message, and the agent ends in a defined status.
      assert_receive {:chat_error, %{content: content}}
      assert content =~ "refusing to send/store"

      assert log =~ "chat_crashed"
      assert log =~ "refusing to send/store"
      assert Machine.status_for(settled.live.machine) == :context_overflow
    end

    test ":reserve_exhausted appends the parked chat request instead of stranding it" do
      # intentional: #29's whole claim is that the message ends up on a payload.
      # This drives the real settle loop (machine decision, executor append,
      # derived status) rather than only asserting an action list. The
      # compaction plan cannot be staged at all when there is no system message
      # and no vocation (`{:error, :reserve_exhausted}`), which is the arm's
      # precondition.
      base = %{state() | vocation: nil}

      machine = %{
        base.live.machine
        | phase: :compaction_failed,
          pending_user_message:
            {:user_message, Dispatch.build_user_message("held message", "chat")}
      }

      state = %{base | live: %{base.live | machine: machine}}

      # The fixture agent has no DB row, so the append's persist step warns;
      # capturing it keeps the suite's console clean and pins that the append
      # went through `MessageAppender`.
      log =
        capture_log(fn ->
          {:ok, settled} = Turn.settle(state, :retry_compaction)
          send(self(), {:settled, settled})
        end)

      assert log =~ "Failed to persist message"
      assert_receive {:settled, settled}

      # A defined status, the slot cleared (so a later resume cannot append the
      # message twice) and the message in the transcript.
      assert Machine.status_for(settled.live.machine) == :idle
      assert settled.live.machine.pending_user_message == nil

      assert [{:user, %User{parts: [%Part.Text{text: text}]}}] = settled.chat_state.messages
      assert text == "[mode: chat]\nheld message"
    end
  end

  describe "Turn.settle quarantine" do
    test "an undeclared event fails the turn to idle instead of wedging it busy" do
      base = state()

      # A busy (non-idle) machine, so the quarantine path must fail the
      # turn rather than leave it stuck. `space_id: nil` keeps the
      # recovery append out of the DB.
      machine = %{
        base.live.machine
        | phase: :generating,
          kind: :chat,
          work: %{base.live.machine.work | worker_kind: :http}
      }

      machine = Machine.owe_replies(machine, ["peer"])
      busy = %{base | space_id: nil, live: %{base.live | machine: machine}}

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{busy.space_id}:#{busy.name}")

      {result, log} =
        with_log(fn ->
          settled = Turn.settle(busy, {:totally_unknown_event})

          # The quarantine is a terminal site, so a reply the turn was holding is
          # given up with it. The requester is unreachable here (`space_id: nil`),
          # so the give-up is refused — and the notification that proves the
          # warning was written arrives after it, inside this capture.
          assert_receive {:chat_notification, %{type: "reply_give_up_failed"}}, 500
          settled
        end)

      assert {:ok, settled} = result
      assert Machine.status_for(settled.live.machine) == :idle
      assert settled.live.machine.owed_replies == %{}
      assert log =~ "quarantined"
      assert log =~ "reply give-up (quarantine) could not reach peer"
      assert_received {:chat_error, %{content: content}}
      assert content =~ "quarantined"
    end
  end
end
