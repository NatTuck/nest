defmodule Nest.Agents.Agent.WaitForIdleTest do
  @moduledoc """
  Coverage for the wait engine behind `agents-wait` (issue #54).

  Two drivers, one subject:

    * the **registration** paths — argument validation, target resolution, and
      a wait with nothing to watch — are driven through the tool
      (`ToolLoop.execute/3`), because the tool result is what the model reads
      and its `is_error` flag and log line are part of the contract;
    * the **event loop** is driven directly through `WaitForIdle.await/6`,
      which is the only way to keep the wake-ups deterministic: the watcher
      runs in its own supervised task (`WatchTest` covers that plumbing), while
      the loop itself is woken here by a real event already in the mailbox —
      the idle status frame a target broadcasts, or a target's `:DOWN` — and by
      a `timeout` whose deadline has already passed. No test sleeps and no test
      waits out a poll.

  The result paths the engine must have:

    * a busy target going idle → the partition, with **all** currently-idle
      names and no payload (issue #62: the wait is synchronisation only);
    * `all: true` → waits for every target;
    * the wall-clock timeout → a normal result, rendered as a distinguishable
      notice.

  Plus the target-resolution rules: `[]` means every other agent in the
  space (never the caller), a name that resolves to no agent is an error
  rather than a silent idle, a read-only wait never starts an agent, and a
  malformed `names`/`timeout`/`all` argument is rejected loudly.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.Agent.WaitForIdle
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult

  setup :verify_on_exit!

  defp ctx do
    %{space_id: 1, agent_name: "caller", context_limit: 100_000, messages: []}
  end

  defp call(args), do: %ToolCall{id: "wait-1", name: "agents-wait", arguments: args}

  # The registration path, through the tool. Only valid for a call that
  # registers nothing — an error, or a wait with nothing to watch — so no agent
  # is involved; a call that registers a watch goes through `await/1`.
  defp run(args) do
    with_log(fn ->
      [%ToolResult{} = result] = ToolLoop.execute(ctx(), nil, [call(args)])
      result
    end)
  end

  # The event loop, driven in-process: the same call the watcher task makes,
  # with no monitor (the caller is this process), rendered by the notice the
  # watcher would deliver.
  defp await(args) do
    {:ok, names, timeout, all?, initial} = WaitForIdle.resolve(ctx(), call(args))

    case WaitForIdle.await(1, names, timeout, all?, initial) do
      {:ok, partition} -> {:ok, WaitForIdle.notice_text(partition)}
      {:timeout, partition} -> {:ok, WaitForIdle.timeout_notice_text(partition, timeout)}
    end
  end

  # The partition a call resolves to before any waiting — what the registration
  # reports inline when there is nothing to watch.
  defp resolved(args) do
    {:ok, _names, _timeout, _all?, partition} = WaitForIdle.resolve(ctx(), call(args))
    partition
  end

  # Drive `Nest.Agents.list_agents_info_for_space/1` from a FIFO of space
  # snapshots: each read pops the next snapshot, and the last one sticks
  # once the list is exhausted. One read answers the initial status
  # question, one the wait's own authoritative read (taken after it
  # subscribes), and one each event-driven recheck, so a frame can flip a
  # target from busy to idle (or drop it from the space entirely). This is
  # the only status source the wait reads — `Nest.Agents.get_info/2` is never
  # called, which is what keeps the wait read-only.
  # `on_read` runs on the n-th read, before the frame for that read is popped.
  # A test that needs something to happen *between* two reads (rather than
  # between two events) uses it, so the ordering is the wait's own read order
  # and not a timer.
  defp stub_listing(frames, opts \\ []) do
    id = {:wait_listing, System.unique_integer([:positive])}
    queue = start_supervised!({Elixir.Agent, fn -> frames end}, id: id)
    on_read = Keyword.get(opts, :on_read, fn _read -> :ok end)
    reads = :counters.new(1, [])

    Mimic.stub(Nest.Agents, :list_agents_info_for_space, fn _space_id ->
      :counters.add(reads, 1, 1)
      on_read.(:counters.get(reads, 1))
      Elixir.Agent.get_and_update(queue, &next_listing/1)
    end)
  end

  # A real process registered under `{space_id, name}`: all `monitor_targets/3`
  # needs from a target is a pid from the registry, and the statuses the wait
  # reads come from the stubbed listing. Killed at the end of the test (or by
  # the test itself) so nothing is left registered under a name the other tests
  # in this file use.
  defp register_target(space_id, name) do
    test_pid = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Nest.Agents.Registry, {space_id, name}, nil)
        send(test_pid, {:registered, self()})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp next_listing([last]), do: {last, [last]}
  defp next_listing([head | rest]), do: {head, rest}

  defp agent(name, status), do: %{name: name, status: status}

  test "reports the partition inline when every target is already idle" do
    stub_listing([[agent("caller", :idle), agent("bob", :idle), agent("carol", :idle)]])

    {named, _log} = run(%{"names" => ["bob", "carol"]})

    assert %ToolResult{name: "agents-wait", is_error: false, content: content} = named
    assert content == "All agents are already idle: bob, carol."

    # An empty list means every other agent in the space (the same set
    # `agents-list` reports). The caller is excluded: it is busy running
    # this very call.
    {all, _log} = run(%{})

    assert %ToolResult{is_error: false, content: content} = all
    assert content == "All agents are already idle: bob, carol."

    # The caller is never a target, however it is named.
    {self_named, _log} = run(%{"names" => ["caller", "bob"]})

    assert %ToolResult{is_error: false, content: content} = self_named
    assert content == "All agents are already idle: bob."

    # An empty space (only the caller) has nothing to wait for and returns
    # immediately rather than erroring.
    stub_listing([[agent("caller", :idle)]])
    {empty, _log} = run(%{})

    assert %ToolResult{is_error: false, content: content} = empty
    assert content == "No other agents in this space to wait for."
  end

  # The registration reports the same partition the engine starts from, so the
  # inline answer and the watch's own reference read cannot disagree.
  test "a wait with something to watch resolves to the busy set" do
    stub_listing([[agent("caller", :idle), agent("bob", :streaming), agent("carol", :idle)]])

    partition = resolved(%{"names" => ["bob", "carol"]})

    assert partition == %{idle: ["carol"], still_busy: ["bob"], gone: []}

    assert WaitForIdle.watch_confirmation(partition) ==
             "Watching (you will be notified): bob. Already idle: carol."
  end

  test "a busy target going idle reports the partition with no payload" do
    # The first snapshot is the caller's reference read and the second the
    # wait's own authoritative read; only the third — reached by the status
    # frame the target broadcasts when it goes idle — shows bob idle, so the
    # event is what the wait is woken by.
    stub_listing([
      [agent("bob", :streaming), agent("carol", :streaming)],
      [agent("bob", :streaming), agent("carol", :streaming)],
      [agent("bob", :idle), agent("carol", :streaming)]
    ])

    send(self(), {:chat_status, %{status: "idle"}})
    assert {:ok, content} = await(%{"names" => ["bob", "carol"], "timeout" => 500})
    assert content == "Agents now idle: bob. Still busy: carol."

    # A target that vanishes mid-wait (no live process, no persisted row)
    # is reported as gone rather than waited out to the timeout.
    stub_listing([[agent("bob", :streaming)], [agent("bob", :streaming)], []])

    send(self(), {:chat_status, %{status: "idle"}})
    assert {:ok, content} = await(%{"names" => ["bob"], "timeout" => 500})
    assert content == "Agents now idle: (none). Still busy: (none). No longer running: bob."
  end

  test "all: true waits until every named target is idle" do
    # The authoritative read still has carol busy, so `any` would return there;
    # `all: true` must keep waiting until the event-driven recheck, where the
    # third snapshot has both idle.
    stub_listing([
      [agent("bob", :idle), agent("carol", :streaming)],
      [agent("bob", :idle), agent("carol", :streaming)],
      [agent("bob", :idle), agent("carol", :idle)]
    ])

    send(self(), {:chat_status, %{status: "idle"}})
    assert {:ok, content} = await(%{"names" => ["bob", "carol"], "all" => true, "timeout" => 500})
    assert content == "Agents now idle: bob, carol. Still busy: (none)."
  end

  # The monitor is the event a dying target cannot broadcast: a stopped,
  # archived or crashed agent emits no status frame at all, so its `:DOWN` is
  # the only thing that can wake a wait that is watching it.
  #
  # This drives exactly that, with the ordering the wait itself establishes: a
  # real process registered under the target's name, and a listing whose
  # *second* read kills it. The wait installs its monitors before each read, so
  # the kill lands after the monitor is in place and before the wait parks —
  # and the third read, the one that reports the target idle, is reachable only
  # through the `:DOWN`. With no monitor there is nothing to wake it, and the
  # wait reports the timeout instead (which is what the assertion below
  # refuses).
  test "a target's death wakes the wait when no frame can" do
    target = register_target(1, "bob")

    stub_listing(
      [
        [agent("bob", :streaming)],
        [agent("bob", :streaming)],
        [agent("bob", :idle)]
      ],
      on_read: fn
        2 -> Process.exit(target, :kill)
        _read -> :ok
      end
    )

    assert {:ok, content} = await(%{"names" => ["bob"], "timeout" => 1_000})
    assert content == "Agents now idle: bob. Still busy: (none)."
  end

  test "the immediate decision is the authoritative read's, not the caller's" do
    # The caller's own read sees both targets idle; by the authoritative read
    # (taken after the subscription) bob is running. `all: true` must keep
    # waiting: returning "Agents now idle: bob, carol" for a target that is
    # running is a lie. This is the one behaviour change from the poll, where
    # the immediate decision used the caller's read, and it is deliberate.
    stub_listing([
      [agent("bob", :idle), agent("carol", :idle)],
      [agent("bob", :streaming), agent("carol", :idle)]
    ])

    assert {:ok, content} = await(%{"names" => ["bob", "carol"], "all" => true, "timeout" => 1})

    assert content ==
             "Timed out after 1ms waiting for agents to go idle. Idle: carol. Still busy: bob."
  end

  test "an unknown target name is an error, not a silent idle" do
    stub_listing([[agent("bob", :idle)]])

    {result, log} = run(%{"names" => ["bob", "ghost"]})

    assert %ToolResult{name: "agents-wait", is_error: true, content: content} = result
    assert content == "Agent ghost not found in this space."
    assert log =~ "BatchSizer produced is_error=true tool result"
  end

  # `Nest.Agents.get_info/2` on-demand-loads a persisted-only agent, so a
  # wait that read statuses through it would start the very agent it is
  # only observing. The listing reports a persisted-only agent as `:idle`
  # without starting it, and both resolution paths use it — so the same
  # agent gets the same disposition however it is named.
  test "a named persisted-only agent is already idle and is never started" do
    Mimic.reject(Nest.Agents, :get_info, 2)

    stub_listing([[agent("caller", :idle), agent("db-only", :idle)]])

    {named, _log} = run(%{"names" => ["db-only"]})

    assert %ToolResult{is_error: false, content: content} = named
    assert content == "All agents are already idle: db-only."

    {all, _log} = run(%{})

    assert %ToolResult{is_error: false, content: content} = all
    assert content == "All agents are already idle: db-only."
  end

  # The schema declares `names` as an array of strings. A bare string, or a
  # list with a non-string element, is a model typo, and silently filtering
  # it would mean "every other agent in the space" — a wait on unrelated
  # agents. Fail loudly instead.
  test "a malformed `names` argument is an error, not an implicit empty list" do
    {not_a_list, log} = run(%{"names" => "bob"})

    assert %ToolResult{name: "agents-wait", is_error: true, content: content} = not_a_list

    assert content ==
             ~s(Invalid `names` argument: expected a list of agent names, got: "bob".)

    assert log =~ "BatchSizer produced is_error=true tool result"

    {bad_element, _log} = run(%{"names" => ["bob", 5]})

    assert %ToolResult{is_error: true, content: content} = bad_element

    assert content ==
             ~s(Invalid `names` argument: expected a list of agent names, got: ["bob", 5].)
  end

  # A non-positive timeout would render "no target changed within -1ms";
  # reject it instead.
  test "a non-positive timeout is an error, not a watch with a negative budget" do
    {result, log} = run(%{"names" => ["bob"], "timeout" => -1})

    assert %ToolResult{name: "agents-wait", is_error: true, content: content} = result

    assert content ==
             "Invalid `timeout` argument: expected a positive integer of milliseconds, " <>
               "got: -1."

    assert log =~ "BatchSizer produced is_error=true tool result"
  end

  test "a non-boolean `all` is an error" do
    {result, log} = run(%{"names" => ["bob"], "all" => "yes"})

    assert %ToolResult{name: "agents-wait", is_error: true, content: content} = result
    assert content == ~s(Invalid `all` argument: expected a boolean, got: "yes".)
    assert log =~ "BatchSizer produced is_error=true tool result"
  end
end
