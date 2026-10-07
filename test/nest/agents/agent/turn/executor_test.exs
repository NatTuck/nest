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
  alias Nest.Agents.Agent.Turn.Executor
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User

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

  defp inbox_state(entries, mode) do
    base = state()
    %{base | live: %{base.live | inbox: entries, mode: mode}}
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

    test "notify_worker sends to the worker pid" do
      {_state, nil} = run({:notify_worker, "kid", self(), {:ok, "resp"}})
      assert_received {:spawn_agent_result, "kid", "resp"}
    end

    test "merge_usage folds descendant usage" do
      {state, nil} = run({:merge_usage, "kid", %{output_tokens: 4}})
      assert state.llm_metrics.descendant_usage.output_tokens == 4
    end

    test "drain_inbox is a no-op on an empty inbox" do
      assert {_state, nil} = run({:drain_inbox})
    end

    test "drain_inbox applies the batch's human mode and otherwise leaves the mode alone" do
      # intentional: one mode per combined message, chosen by
      # `Inbox.drain_mode/1` and applied here (never at enqueue time, where
      # it would re-resolve the ongoing turn's caps).
      peer = %{
        from: "peer",
        content: "peer note",
        timestamp: DateTime.utc_now(),
        kind: :agent,
        mode: nil
      }

      human = %{
        from: "alice",
        content: "human note",
        timestamp: DateTime.utc_now(),
        kind: :user,
        mode: "plan"
      }

      # A human mode in the batch wins, and the combined text labels both kinds.
      {state, {:inbox_drain, [^peer, ^human], content}} =
        run({:drain_inbox}, inbox_state([peer, human], "chat"))

      assert state.live.inbox == []
      assert state.live.mode == "plan"
      assert content =~ "[Message from the user \"alice\"]\nhuman note"
      assert content =~ "[Message from agent \"peer\"]\npeer note"

      # An agent-only batch leaves the agent's current mode alone.
      {state, {:inbox_drain, [^peer], _content}} =
        run({:drain_inbox}, inbox_state([peer], "chat"))

      assert state.live.mode == "chat"

      # A mode the vocation does not define resolves to its default, exactly
      # as an idle chat's request would, so `currentMode` never holds a mode
      # the vocation does not define.
      bogus = %{human | mode: "bogus"}

      {state, {:inbox_drain, [^bogus], _content}} =
        run({:drain_inbox}, inbox_state([bogus], "chat"))

      assert state.live.mode == "chat"
    end

    test "restore_inbox restores entries and broadcasts" do
      state = state()
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      entry = %{
        from: "a",
        content: "c",
        timestamp: DateTime.utc_now(),
        kind: :agent,
        mode: nil
      }

      {state, nil} = run({:restore_inbox, [entry]}, state)
      assert state.live.inbox == [entry]
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

      busy = %{base | space_id: nil, live: %{base.live | machine: machine}}

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{busy.space_id}:#{busy.name}")

      {result, log} = with_log(fn -> Turn.settle(busy, {:totally_unknown_event}) end)

      assert {:ok, settled} = result
      assert Machine.status_for(settled.live.machine) == :idle
      assert log =~ "quarantined"
      assert_received {:chat_error, %{content: content}}
      assert content =~ "quarantined"
    end
  end
end
