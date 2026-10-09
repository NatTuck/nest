defmodule Nest.Agents.Agent.TimelineEmittersTest do
  @moduledoc """
  §3 of W2: the `Nest.Timeline` emitters, driven through the runtime's own
  paths.

  `notes/w2-emitters.md` is the site → event → payload table; this file is the
  evidence that each site records what the table says. Where a site has a real
  path — a chat turn, a peer delivery, a spawn, a compaction, a give-up — the
  test drives that path instead of calling the emitter, because the contract is
  that the *runtime* records.

  Recording is enabled through application config and writes into a tmp
  directory, which is global state; the module is therefore `async: false`, the
  same reason `Nest.TimelineTest` is. The tests are grouped by the agent they
  drive rather than one per emitter: a real agent turn is the expensive part,
  and the assertions of one group do not conflict with another's.
  """

  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn
  alias Nest.LLM.MockClient
  alias Nest.Timeline
  alias Nest.Timeline.Digest
  alias Nest.Vocations

  import Nest.Agents.AgentTestHelpers
  import Nest.Agents.AgentTurnTestHelpers

  setup :verify_on_exit!

  setup do
    dir =
      Path.join(System.tmp_dir!(), "nest-timeline-emitters-#{System.unique_integer([:positive])}")

    Application.put_env(:nest, :timeline_dir, dir)
    Application.put_env(:nest, :timeline_enabled, true)

    # The MockClient queue belongs to the test pid until `start_agent/1`
    # transfers it to the agent (the `TurnAcceptanceTest` fixture).
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn ->
      Application.delete_env(:nest, :timeline_dir)
      Application.delete_env(:nest, :timeline_enabled)
      Process.delete(:nest_test_agent_pid)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "a chat turn records its transitions, its request, its usage, the status and the inbox" do
    MockClient.set_stream_events([
      {:text, "hello from the mock"},
      {:usage,
       %{input_tokens: 12, output_tokens: 7, total_tokens: 19, cache_read_input_tokens: 3}}
    ])

    {pid, name} = start_agent(default_attrs())
    track_agent(name)
    space_id = current_space_id()

    :ok = Agent.chat(pid, "hi")
    assert statuses_until_idle() == ["streaming", "idle"]

    # The worker's own exit is the turn's last transition, and it lands after
    # the idle status this test waits on; waiting for the record makes both the
    # transition list and the digest below deterministic.
    assert Eventually.eventually(
             fn -> Enum.any?(events("turn"), &(&1["event"] == "worker_down")) end,
             timeout: 500
           )

    # One `turn` event per `Machine.step/2` call, in settle order, with the
    # placement before and after.
    assert [
             %{"event" => "chat_request", "from" => from, "to" => to},
             %{"event" => "iterate"},
             %{"event" => "worker_started"},
             %{"event" => "http_ok"},
             %{"event" => "worker_down"}
           ] = events("turn")

    assert from == %{"kind" => "chat", "phase" => "idle"}
    assert to == %{"kind" => "chat", "phase" => "generating"}

    # The user message's index is only knowable after the executor stamped it,
    # so the transition that appended it carries the diff.
    assert [%{"event" => "chat_request", "message_indices" => [index]}] =
             Enum.filter(events("turn"), &(&1["event"] == "chat_request"))

    assert is_integer(index)

    # The request line: the sizing numbers the request actually cost.
    state = :sys.get_state(pid)
    limit = state.llm_metrics.context_limit

    assert [
             %{
               "message_index" => next_index,
               "iteration" => 1,
               "model" => "qwen3.5-plus",
               "projected_tokens" => projected,
               "limit" => ^limit,
               "reserve" => reserve,
               "outcome" => "sent"
             }
           ] = events("llm")

    # The request line names the index the *response* will take (the next one to
    # be assigned), which is one past the user message it answers.
    assert next_index == index + 1
    assert projected > 0
    assert reserve == max(8_192, round(limit * 0.20))
    assert [%{"remaining" => remaining}] = events("llm")
    assert remaining >= 0

    # The usage line translates the client's long names to the schema's short
    # ones, and is the only place that translation happens.
    assert [
             %{"input" => 12, "output" => 7, "total" => 19, "cache_read" => 3, "cache_write" => 0}
           ] = events("usage")

    # The status line carries the broadcast payload verbatim, so a reader can
    # answer "what did the UI actually see".
    assert Enum.map(events("status"), & &1["payload"]["status"]) == ["streaming", "idle"]
    assert [%{"payload" => payload} | _] = events("status")
    assert payload["model"]["name"] == "qwen3.5-plus"

    # The digest renders the run this test just produced.
    digest = Digest.render(Timeline.run_dir(), agent: name)
    assert digest =~ "  turns: 5   llm requests: 1   tokens: in 12 out 7 cache r 3 w 0"
    assert digest =~ "chat/idle → chat/generating · chat_request · iter 0/5 · message_indices=[1]"
    assert digest =~ "chat/generating → chat/idle · http_ok · iter 1/5 · message_indices=[2]"

    assert digest =~
             "##{next_index} iter 1 · #{projected}/#{limit} projected " <>
               "(reserve #{reserve}, remaining #{remaining}) · qwen3.5-plus · sent"

    # --- the same agent's inbox: each disposition, the drain, and an enqueue ---

    # Idle target: delivered, and the drain that follows it.
    assert {:ok, :delivered} = Agents.send_message(space_id, "peer", name, "hello", :agent)
    assert statuses_until_idle() == ["streaming", "idle"]

    # Busy target: queued.
    set_status(pid, :streaming)
    assert {:ok, :queued} = Agents.send_message(space_id, "peer", name, "while busy", :agent)

    # A human message while busy takes the other enqueue path, which never
    # refuses.
    assert :ok = Agent.chat(pid, "queued by a human")

    # Broken target: refused with the status the sender was told.
    set_status(pid, :needs_repair)

    assert {:error, {:status, :needs_repair}} =
             Agents.send_message(space_id, "peer", name, "nope", :agent)

    # Full inbox: refused by the cap.
    fill_inbox(pid, 100)
    assert {:error, :inbox_full} = Agents.send_message(space_id, "peer", name, "nope", :agent)

    # The fabricated state is test-only: leave the agent idle and the queue empty
    # so the teardown's zero-in-flight assertion holds.
    set_status(pid, :idle)
    fill_inbox(pid, 0)

    assert [
             %{
               "action" => "delivered",
               "from" => "peer",
               "kind" => "agent",
               "bytes" => 5,
               "count" => 1,
               "mode" => nil,
               "disposition" => "delivered"
             }
           ] = inbox_action("delivered")

    assert [%{"action" => "queued", "count" => 1, "disposition" => "queued"}] =
             inbox_action("queued")

    assert [%{"action" => "enqueued", "from" => nil, "kind" => "user", "count" => 2}] =
             inbox_action("enqueued")

    # The refusals record the value the sender was given, not a re-derivation.
    assert [%{"action" => "refused", "from" => "peer", "count" => nil}] =
             inbox_disposition("{:status, :needs_repair}")

    assert [%{"action" => "refused", "bytes" => 4, "disposition" => "inbox_full"}] =
             inbox_disposition("inbox_full")

    # A drain's own line: the batch it delivered, with the mode it resolved.
    assert [%{"action" => "drained", "count" => 1, "from" => "peer", "mode" => "chat"}] =
             inbox_action("drained")
  end

  test "a spawn records the child, its tool result, its outcome, its cost and its archive" do
    parent_vocation = programmer_vocation_id_for_test()
    specialist_slug = specialist_vocation_slug()

    Mimic.stub(Agents, :chat, fn _space_id, _name, _content -> :ok end)

    child_name = "kid-#{System.unique_integer([:positive])}"

    MockClient.set_tool_response(%{
      text: "spawning",
      tool_calls: [
        %{
          id: "call_spawn_1",
          name: "agents-spawn",
          arguments: %{
            "name" => child_name,
            "vocation" => specialist_slug,
            "query" => "do the thing",
            "archive" => true
          }
        }
      ]
    })

    MockClient.set_response("spawned it")
    MockClient.set_response("thanks for the answer")

    {pid, name} = start_agent(%{model: %{name: "qwen3.5-plus"}, vocation_id: parent_vocation})
    track_agent(name)

    # The spawned specialist must not run a turn of its own here: its chat is
    # stubbed, and the parent is the process that calls it.
    Mimic.allow(Agents, self(), pid)

    :ok = Agent.chat(pid, "delegate this")

    # The tool batch is its own status; the turn then streams the final reply.
    statuses = statuses_until_idle()
    assert hd(statuses) == "streaming"
    assert "executing_tools" in statuses

    # The tool result path records one line per result, with the worker that
    # produced the batch.
    assert [
             %{
               "name" => "agents-spawn",
               "tool_call_id" => "call_spawn_1",
               "is_error" => false,
               "args_bytes" => args_bytes,
               "result_bytes" => result_bytes,
               "worker" => "tools"
             }
           ] = events("tool")

    assert args_bytes > 0
    assert result_bytes > 0

    # The spawn line carries the five fields only the spawn site has.
    assert [
             %{
               "action" => "spawned",
               "name" => ^child_name,
               "vocation" => ^specialist_slug,
               "depth" => 1,
               "model" => "qwen3.5-plus",
               "clone_context" => false,
               "archive" => true
             }
           ] = child_action("spawned")

    # The child's outcome arrives as a cast in the real runtime; its delivery
    # into the parent's own inbox (idle, so the drain starts a turn) is what
    # makes the parent record the completion, the cost and the archive. The
    # status rebroadcast that comes with it is why this waits on the record
    # rather than on the status stream.
    GenServer.cast(pid, {:child_completed, child_name, "the answer", child_usage()})

    assert Eventually.eventually(
             fn ->
               child_action("archived") != [] and
                 Machine.status_for(:sys.get_state(pid).live.machine) == :idle
             end,
             timeout: 500
           )

    assert [%{"action" => "completed", "name" => ^child_name}] = child_action("completed")
    assert [%{"action" => "archived", "name" => ^child_name}] = child_action("archived")

    # A child's cost is recorded against the parent — the agent that owns the
    # totals it lands in — with the child's name on the line.
    assert [%{"name" => ^child_name, "input" => 30, "output" => 4, "total" => 34}] =
             child_usage_events(child_name)
  end

  test "a debt, a compaction and an undeclared event are recorded where they happen" do
    # A query from a peer that does not exist: the debt is set at delivery, the
    # gate reminds once, and the runtime then gives it up and cannot reach the
    # requester. Two replies are scripted because the reminder keeps the turn
    # alive for one more iteration; the third response is the compactor's.
    MockClient.set_response("first reply")
    MockClient.set_response("second reply")
    MockClient.set_response("a summary of the conversation")

    {pid, name} = start_agent(default_attrs())
    track_agent(name)
    space_id = current_space_id()
    state = :sys.get_state(pid)

    log =
      capture_log(fn ->
        assert {:ok, :delivered} =
                 Agents.send_message(space_id, "ghost", name, "question?", :query)

        assert statuses_until_idle() == ["streaming", "idle"]

        # An undeclared event has no transition and so no `turn` line: the
        # `error` type carries the quarantine. The broadcast site records the
        # source tag it was given.
        assert {:ok, _state} = Turn.settle(state, {:undeclared_thing, 1})
        Broadcasts.error(space_id, state.name, 0, "boom", "Turn.run/2")
      end)

    assert log =~ "reply give-up (no_reminder) could not reach ghost"
    assert log =~ "quarantined undeclared turn event"
    assert log =~ "boom"

    assert [
             %{"action" => "set", "peer" => "ghost", "reminders_used" => 0, "how" => "delivered"},
             %{"action" => "reminded", "peer" => "ghost", "reminders_used" => 1, "how" => "gate"},
             %{
               "action" => "gave_up",
               "peer" => "ghost",
               "reminders_used" => 1,
               "how" => "no_reminder"
             },
             %{"action" => "give_up_refused", "peer" => "ghost", "how" => ":not_found"}
           ] = events("debt")

    # The refusal is broadcast too, so the operator sees it as well as the log.
    assert [%{"notification_type" => "reply_give_up_failed", "message" => message}] =
             events("notification")

    assert message =~ "Could not tell ghost"

    assert [
             %{"source" => "Turn.quarantine!/2", "message" => quarantine},
             %{"source" => "Turn.run/2", "message" => "boom"}
           ] = events("error")

    assert quarantine =~ "quarantined turn event"

    # A manual compaction: the trigger line omits `trigger` (it is decided in a
    # pure module and does not ride the action), the commit line carries it.
    assert :ok = GenServer.call(pid, {:compact, nil})
    assert statuses_until_idle() == ["compacting", "idle"]

    assert [staged, committed] = events("compaction")
    refute Map.has_key?(staged, "trigger")
    assert staged["used"] > 0
    assert staged["projected"] == staged["used"] + staged["reserve"]
    assert staged["carried"] == nil
    assert staged["archived_to_index"] == nil

    # The commit line reads as the compaction's before → after.
    assert committed["trigger"] == "commit"
    assert committed["archived_to_index"] > 0
    assert committed["used"] > committed["projected"]

    # Recording off: the emitters build nothing and write nothing. The check is
    # scoped to the message *this* settle would have recorded, so a background
    # worker settling its own `turn` event for this agent cannot falsify it.
    Application.put_env(:nest, :timeline_enabled, false)

    quarantines = fn ->
      Enum.count(events("error"), &(&1["message"] =~ "another_undeclared"))
    end

    before = quarantines.()

    capture_log(fn -> assert {:ok, _state} = Turn.settle(state, {:another_undeclared, 2}) end)

    assert quarantines.() == before
  end

  test "the debt diff records each branch of the obligation's change" do
    {pid, name} = start_agent(default_attrs())
    track_agent(name)

    state = :sys.get_state(pid)
    before = state.live.machine

    # not owed → owed: the delivery that incurred the obligation.
    owed = Machine.owe_replies(before, ["peer"])
    assert :ok = Agent.Timeline.debt_changes(state, before, owed)

    # the count grew: the reminder gate.
    reminded = Machine.count_reminders(owed, ["peer"])
    assert :ok = Agent.Timeline.debt_changes(state, owed, reminded)

    # owed → not owed: the reply-sent discharge, the only in-step clear.
    discharged = Machine.discharge_reply(reminded, "peer")
    assert :ok = Agent.Timeline.debt_changes(state, reminded, discharged)

    assert [
             %{"action" => "set", "peer" => "peer", "reminders_used" => 0, "how" => "delivered"},
             %{"action" => "reminded", "peer" => "peer", "reminders_used" => 1, "how" => "gate"},
             %{
               "action" => "cleared",
               "peer" => "peer",
               "reminders_used" => 1,
               "how" => "reply_sent"
             }
           ] = events("debt")

    # A step that changed nothing records nothing: the diff *is* the record, so
    # a diff that silently stops matching is exactly the failure a diagnostic
    # must not have, and this is what pins it.
    assert :ok = Agent.Timeline.debt_changes(state, discharged, discharged)
    assert length(events("debt")) == 3
  end

  test "a child's terminal outcomes are each recorded as their own action" do
    {pid, name} = start_agent(default_attrs())
    track_agent(name)
    state = :sys.get_state(pid)

    # Each child is terminal exactly once, so each outcome needs its own name.
    # The state is threaded per child: the second settle is the one that has to
    # find the child registered.
    for {child, event, action} <- [
          {"kid-failed", {:child_failed, "kid-failed", :boom}, "failed"},
          {"kid-terminated", {:child_terminated, "kid-terminated", :killed}, "terminated"},
          {"kid-abandoned", {:abandon_child, "kid-abandoned"}, "stopped"}
        ] do
      assert {:ok, spawned} = Turn.settle(state, {:child_spawned, child, false, nil})
      assert {:ok, _settled} = Turn.settle(spawned, event)
      assert [%{"action" => ^action, "name" => ^child}] = child_action(action)
    end

    # A result shape the runtime does not know is rendered, not dropped: a
    # diagnostic must not lose the one event it did not expect.
    assert :ok = Agent.Timeline.child_message(state, "kid-unknown", {:weird, 1})
    assert [%{"action" => "{:weird, 1}", "name" => "kid-unknown"}] = child_action("{:weird, 1}")
  end

  test "the emitters record what they can and skip what has no event" do
    {pid, name} = start_agent(default_attrs())
    track_agent(name)
    state = :sys.get_state(pid)
    machine = state.live.machine

    # A notification payload the runtime does not recognise still records its
    # line, with the two fields it could not read as nil. (It also creates the
    # run's file, which the assertions below read through.)
    assert :ok = Agent.Timeline.notification(state.space_id, name, :not_a_map)
    assert [%{"notification_type" => nil, "message" => nil}] = events("notification")

    # A request the runtime cannot size: the limit is not a positive integer, so
    # `reserve`/`remaining` are nil rather than a fabricated number.
    ctx = %{Turn.build_ctx(state) | context_limit: nil}
    assert :ok = Agent.Timeline.llm_request(state, ctx)
    assert [%{"limit" => nil, "reserve" => nil, "remaining" => nil}] = events("llm")

    # A value the client handed over that is not the shape the emitter expects:
    # no line, and no raise into the caller.
    assert :ok = Agent.Timeline.usage(state, :not_a_map)
    assert :ok = Agent.Timeline.child_usage(state, "kid", :not_a_map)
    assert events("usage") == []

    # An event that is not a tool batch has no results to record.
    assert :ok = Agent.Timeline.tools(state, :iterate, machine)
    assert events("tool") == []

    # A drain that delivered nothing has no batch to record.
    assert :ok = Agent.Timeline.drained(state, [])
    assert inbox_action("drained") == []

    # A drain whose entries are not the shape the emitter expects is reported and
    # skipped, not raised into the drain that called it: the payload is built
    # inside the emitter's rescue (and only when recording is on at all).
    log = capture_log(fn -> assert :ok = Agent.Timeline.drained(state, [:not_a_map]) end)
    assert log =~ "the inbox emitter failed"
    assert inbox_action("drained") == []

    # The spawn line's model: the runtime passes a resolved map, and the
    # fallbacks cover a bare name and a value that names nothing.
    models =
      for model <- [%{name: "m"}, "m", 42, nil] do
        assert :ok = Agent.Timeline.child_spawned(state, "kid", model, %{})
        List.last(child_action("spawned"))["model"]
      end

    assert models == ["m", "m", nil, nil]

    # The compaction's carried continuation: the entry's tag when the staged
    # request carries one, nil when it carries none or there is no compaction
    # entry at all.
    carried =
      for entry <- [
            {:compaction, :staged, {:assistant_response, "text", []}},
            {:compaction, :staged, nil},
            nil
          ] do
        :sys.replace_state(pid, fn s ->
          %{s | live: %{s.live | machine: %{machine | entry: entry}}}
        end)

        assert :ok = Agent.Timeline.compaction_staged(:sys.get_state(pid), ctx)
        List.last(events("compaction"))["carried"]
      end

    assert carried == ["assistant_response", nil, nil]

    # Leave the fabricated machine as it was found.
    :sys.replace_state(pid, fn s -> %{s | live: %{s.live | machine: machine}} end)
  end

  test "a malformed timeline directory does not raise out of an emitter" do
    dir = Application.get_env(:nest, :timeline_dir)

    {pid, name} = start_agent(default_attrs())
    track_agent(name)
    state = :sys.get_state(pid)

    # `:timeline_dir` is read at call time, and a non-binary value makes
    # `Path.join/2` raise inside the writer. These emitters call `record/4`
    # directly and have no rescue of their own — `give_up_refused/4` runs inside
    # the executor — so the writer's own guard is the only thing keeping a settle
    # alive. (A value no other test disables under: the disable flag is
    # per-key, and it outlives the test that set it.)
    Application.put_env(:nest, :timeline_dir, :not_a_dir)

    log =
      capture_log(fn ->
        assert :ok = Agent.Timeline.give_up_refused(state.space_id, name, "peer", :not_found)
        assert :ok = Agent.Timeline.notification(state.space_id, name, %{type: "x", message: "y"})
        assert :ok = Agent.Timeline.error(state.space_id, name, "boom", "Turn.run/2")
        assert :ok = Agent.Timeline.drained(state, [%{from: "peer", kind: :agent, content: "x"}])
      end)

    assert log =~ "recording disabled"

    Application.put_env(:nest, :timeline_dir, dir)
  end

  # --- helpers ---

  defp default_attrs do
    %{model: %{name: "qwen3.5-plus"}, vocation_id: programmer_vocation_id_for_test()}
  end

  # Every event this test's agent recorded. The run file is per OS process, and
  # recording is switched on globally, so a write from another test's process
  # (a worker still finishing while this module runs) would otherwise land in
  # the middle of an assertion. The digest is filtered the same way, through
  # `Digest.render/2`'s own `:agent` option.
  defp events do
    {events, problems} = Timeline.load(Timeline.run_dir())
    assert problems == []
    Enum.filter(events, &(&1["agent"] == agent_name()))
  end

  defp agent_name, do: Process.get(:timeline_test_agent)

  defp track_agent(name), do: Process.put(:timeline_test_agent, name)

  defp events(type), do: Enum.filter(events(), &(&1["type"] == type))

  defp child_action(action), do: Enum.filter(events("child"), &(&1["action"] == action))

  defp inbox_action(action), do: Enum.filter(events("inbox"), &(&1["action"] == action))

  defp inbox_disposition(value), do: Enum.filter(events("inbox"), &(&1["disposition"] == value))

  defp child_usage_events(name), do: Enum.filter(events("usage"), &(&1["name"] == name))

  defp child_usage do
    %{
      input_tokens: 30,
      output_tokens: 4,
      total_tokens: 34,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0
    }
  end

  defp set_status(pid, status) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{state.live | machine: Machine.status_to_machine(state.live.machine, status)}
      }
    end)
  end

  defp fill_inbox(pid, count) do
    entry = %{
      from: "peer",
      content: "queued",
      timestamp: DateTime.utc_now(),
      kind: :agent,
      mode: nil
    }

    :sys.replace_state(pid, fn state ->
      %{state | live: %{state.live | inbox: List.duplicate(entry, count)}}
    end)
  end

  # A distinct vocation for the spawned specialist; returns its slug.
  defp specialist_vocation_slug do
    {:ok, %Vocations.Vocation{slug: slug}} =
      Vocations.upsert_vocation(%{
        name: "Timeline Specialist #{System.unique_integer([:positive])}",
        description: "A specialist",
        system_prompt: "You are a specialist.",
        tools: ["context"],
        modes: %{}
      })

    slug
  end
end
