defmodule Nest.Agents.Agent.WatchTest do
  @moduledoc """
  Coverage for the non-blocking waits (issues #54 + #62): the bare notice, the
  satisfied-watch suppression, and watcher lifetime.

  The tool is driven directly with a `ctx` carrying the real agent pid (the
  way `ToolLoop.execute/3` is called in production) so the watch is registered
  on a real agent without running a whole turn; the listing is stubbed to drive
  the watcher's status reads.
  """
  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.Agent.Watch
  alias Nest.Agents.AgentStateHelpers
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs
  alias Nest.Tools.ShellCmd

  setup :verify_on_exit!

  setup do
    {pid, name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
    %{pid: pid, name: name, space_id: AgentTestHelpers.current_space_id()}
  end

  defp ctx(pid, name, space_id) do
    %{space_id: space_id, agent_name: name, agent_pid: pid, context_limit: 100_000, messages: []}
  end

  defp wait(pid, name, space_id, args) do
    [%ToolResult{} = result] =
      ToolLoop.execute(ctx(pid, name, space_id), nil, [
        %ToolCall{id: "w1", name: "agents-wait", arguments: args}
      ])

    result
  end

  defp agent(name, status), do: %{name: name, status: status}

  # Drive `list_agents_info_for_space/1` from a FIFO of snapshots; the last
  # sticks. The wait reads the listing for its reference partition, once more
  # after subscribing, and again on each event it is woken by, so a frame can
  # flip a target busy → idle. `Elixir.Agent` is the stdlib queue process —
  # `Agent` here is `Nest.Agents.Agent`.
  defp stub_listing(frames) do
    id = {:watch_listing, System.unique_integer([:positive])}
    queue = start_supervised!({Elixir.Agent, fn -> frames end}, id: id)

    Mimic.stub(Nest.Agents, :list_agents_info_for_space, fn _space_id ->
      Elixir.Agent.get_and_update(queue, &next_listing/1)
    end)
  end

  defp next_listing([last]), do: {last, [last]}
  defp next_listing([head | rest]), do: {head, rest}

  defp watchers(pid), do: Agent.get_watches(pid, 1_000)

  # The notice drains into a turn; the turn's own idle status frame is the event
  # that says it finished. A bare `idle` is not that fence: a turn end that
  # drains publishes the transient `streaming -> idle -> streaming` of issue #15
  # first, so the fence is the idle that carries an empty queue. The status read
  # that follows is a read of the settled state, not a wait.
  defp await_idle(pid) do
    assert_receive {:chat_status, %{status: "idle", pendingMessageCount: 0}}, 1_000

    assert Agent.get_public_info(pid, 1_000).status == :idle
  end

  defp notices(pid) do
    Agent.get_messages(pid, 1_000)
    |> Enum.flat_map(fn
      {:user, %{parts: parts}} -> Enum.map(parts, & &1.text)
      _ -> []
    end)
  end

  test "an already-idle-only wait registers nothing", %{pid: pid, name: name, space_id: space_id} do
    stub_listing([[agent(name, :idle), agent("bob", :idle)]])

    result = wait(pid, name, space_id, %{"names" => ["bob"]})

    # Nothing to watch: the partition is reported inline, with no marker, so
    # the machine lets the turn continue (issue #54).
    assert %ToolResult{is_error: false, state: nil} = result
    assert watchers(pid) == %{}
  end

  test "the watcher fires a bare notice when the target goes idle", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    stub_listing([
      [agent(name, :idle), agent("bob", :streaming)],
      [agent(name, :idle), agent("bob", :idle)]
    ])

    MockClient.set_response("acknowledged")
    _ = wait(pid, name, space_id, %{"names" => ["bob"]})

    # The notice is delivered while the agent is idle, so it drains and starts
    # a turn with the bare synchronisation text — never a payload. That turn's
    # own user-message broadcast is the event; the transcript read below is a
    # read, not a wait.
    assert_receive {:chat_message, {:user, _}}, 1_000

    # The wake's *kind* is pinned through its render, because the render is
    # the only thing the kind decides: a `:runtime` entry is headered
    # `[From nest runtime | mode: …]`, where a peer's delivery carries a
    # `[Message from agent …]` label instead. The wording alone pins nothing —
    # a peer-labelled delivery says "Agents now idle" too — so a
    # `Watch.fired/3` that passed any other kind would slip through a
    # text-containment assertion.
    assert [delivered] = Enum.filter(notices(pid), &(&1 =~ "Agents now idle"))
    assert delivered =~ "[From nest runtime"

    # The watch is dropped on the way out, so a second frame cannot wake it.
    assert watchers(pid) == %{}
    await_idle(pid)
  end

  # The satisfaction rule is "the watched agent's own delivery woke me". A
  # delivery that was *refused* woke nobody: the entry is dropped and the sender
  # is told so. Marking the watch satisfied on the way past silenced the wait
  # completely — `Watch.fired/2`'s satisfied arm skips the notice, and that arm
  # is the one both the idle event *and* the timeout go through, so the caller
  # was never told by anything.
  test "a refused delivery does not satisfy the watch", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    # Four reads, in order: the registration's own partition, the watcher's
    # reference read, the watcher's authoritative read (still busy, so the wait
    # blocks), and the re-read the status frame triggers.
    stub_listing([
      [agent(name, :idle), agent("bob", :streaming)],
      [agent(name, :idle), agent("bob", :streaming)],
      [agent(name, :idle), agent("bob", :streaming)],
      [agent(name, :idle), agent("bob", :idle)]
    ])

    _ = wait(pid, name, space_id, %{"names" => ["bob"]})
    assert [{_ref, %{satisfied: false}}] = Map.to_list(watchers(pid))

    # The caller is broken, so bob's message is refused rather than queued.
    AgentStateHelpers.set_status(pid, :needs_repair)

    assert {:error, {:status, :needs_repair}} =
             Agent.deliver_note(pid, "bob", "an answer nobody can take", :agent)

    # The refusal is not a wake: the watch is still outstanding and unsatisfied.
    assert [{_ref, %{satisfied: false}}] = Map.to_list(watchers(pid))

    # ...so bob going idle still has to fire it.
    AgentStateHelpers.set_status(pid, :idle)
    MockClient.set_response("acknowledged")

    # The frame goes to the watcher task directly rather than onto bob's topic.
    # The watcher subscribes inside its own task, and `start_child` returns
    # before that body runs, so a broadcast sent from here could land before the
    # subscription and wake nobody — while a direct frame waits in the task's
    # mailbox for the loop that matches it (`WaitForIdle.loop/8` matches the
    # frame, not its sender). The same argument as the test above.
    [{_ref, %{pid: task}}] = Map.to_list(watchers(pid))
    send(task, {:chat_status, %{status: "idle"}})

    assert_receive {:chat_message, {:user, %{parts: parts}}}, 1_000
    text = Enum.map_join(parts, "", & &1.text)
    assert text =~ "Agents now idle: bob"

    # The notice's turn has to finish before the test does (the teardown asserts
    # no agent is left mid-turn).
    await_idle(pid)
  end

  test "a timeout delivers a distinguishable bare notice", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    stub_listing([[agent(name, :idle), agent("bob", :streaming)]])
    MockClient.set_response("acknowledged")

    _ = wait(pid, name, space_id, %{"names" => ["bob"], "timeout" => 50})

    # The notice drains into a turn; that turn's own user-message broadcast is
    # the event that says the notice landed. The expiry is a distinct branch
    # from a fire, and its text is what makes an expired watch distinguishable
    # from one that fired.
    assert_receive {:chat_message, {:user, _}}, 1_000

    assert [_] = Enum.filter(notices(pid), &(&1 =~ "Timed out after 50ms"))
    await_idle(pid)
  end

  test "firing an unknown watch is a no-op" do
    state = %Agent{live: %Agent.ChatState.Live{}}
    assert {^state, :skipped} = Watch.fired(state, make_ref(), "notice")
  end

  test "stop_all kills every watcher and clears the map", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    stub_listing([[agent(name, :idle), agent("bob", :streaming)]])
    _ = wait(pid, name, space_id, %{"names" => ["bob"]})

    [{_ref, %{pid: task}}] = Map.to_list(watchers(pid))
    mref = Process.monitor(task)

    # allowlist: harness — Watch.stop_all/1's argument
    state = :sys.get_state(pid, 1_000)
    assert Watch.stop_all(state).live.watches == %{}
    assert_receive {:DOWN, ^mref, :process, ^task, _reason}, 1_000
  end

  test "the watcher dies with its caller" do
    # A watcher monitors the process it reports to, so a caller that dies (a
    # crash, an archive, a supervisor shutdown) leaves no watcher behind. Drive
    # it with a throwaway caller so the agent under test is untouched.
    stub_listing([[agent("caller", :idle), agent("bob", :streaming)]])

    caller =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = make_ref()

    {:ok, task} = Watch.start(caller, ref, {:agent_idle, 1, ["bob"], 2_000, false})
    mref = Process.monitor(task)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^mref, :process, ^task, _reason}, 1_000
  end

  test "stopping the agent kills its watchers", %{pid: pid, name: name, space_id: space_id} do
    # The agent's `terminate/2` kills every outstanding watcher, so a stopped
    # agent never leaves one behind. Trap the link exit the helper makes so the
    # stop does not take the test process with it.
    Process.flag(:trap_exit, true)
    stub_listing([[agent(name, :idle), agent("bob", :streaming)]])
    _ = wait(pid, name, space_id, %{"names" => ["bob"]})

    [{_ref, %{pid: task}}] = Map.to_list(watchers(pid))
    mref = Process.monitor(task)

    _ = Supervisor.stop_agent(space_id, name)

    assert_receive {:DOWN, ^mref, :process, ^task, _reason}, 1_000
  end

  # The headline for #62 + #54: the caller registers, returns, goes idle; the
  # target's own delivery wakes it with the report **exactly once**, and the
  # watch (satisfied by that delivery) fires only to be skipped — never a
  # second, bare wake.
  #
  # This rests on the settle loop's target-side ordering: the completion is sent
  # *before* the status broadcast, so a delivery is always in the caller's inbox
  # by the time idle is observable (`turn.ex:63-70` — "Effects land before the
  # status change is announced"). A refactor that broadcast the status first
  # would break the premise, so the assertion below is deliberately on the wake,
  # not just on the watch being cleared.
  test "the target's delivery wakes the idle caller exactly once", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    stub_listing([
      # resolve: the target is busy, so a watch is registered
      [agent(name, :idle), agent("bob", :streaming)],
      # the watcher's reference read, then its authoritative read: still busy
      [agent(name, :idle), agent("bob", :streaming)],
      [agent(name, :idle), agent("bob", :streaming)],
      # the recheck the target's status frame drives: bob is idle now, so it fires
      [agent(name, :idle), agent("bob", :idle)]
    ])

    MockClient.set_response("read the report")
    _ = wait(pid, name, space_id, %{"names" => ["bob"]})

    # The target's completion, delivered the way the runtime delivers a child's
    # (`Inbox.enqueue_internal/6`, kind `:agent`). The caller is idle, so this
    # starts its turn.
    assert {:ok, :delivered} = Agent.deliver_internal(pid, "bob", "the report", :agent)

    # Then the target's own status frame — the event the wait is woken by. It
    # fires, finds the watch satisfied by that delivery, and is skipped: the
    # caller is not woken a second time. `fired/3` unregisters before
    # delivering, so assert the wake itself too — exactly one user turn (the
    # report), no bare notice in the transcript or still queued.
    #
    # The frame is delivered to the watcher task directly rather than broadcast
    # on the target's topic: the watcher subscribes inside its own task, so a
    # broadcast sent from here could land before that subscription, while a
    # direct frame waits in the task's mailbox for the loop that matches it
    # (`WaitForIdle.loop/8` matches the frame, not its sender).
    [{_ref, %{pid: task}}] = Map.to_list(watchers(pid))
    mref = Process.monitor(task)
    send(task, {:chat_status, %{status: "idle"}})

    # `watch_fired/3` is a call, so the task cannot exit until the watch has
    # been unregistered: the `:DOWN` proves the wake landed and the map is
    # clear.
    assert_receive {:DOWN, ^mref, :process, ^task, _reason}, 1_000
    assert watchers(pid) == %{}

    await_idle(pid)

    texts = notices(pid)
    assert length(texts) == 1
    assert Enum.count(texts, &(&1 =~ "the report")) == 1
    refute Enum.any?(texts, &(&1 =~ "Agents now idle"))
  end

  test "shell-wait registers and the notice carries the job output", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    # `shell-wait` follows the same shape as `agents-wait`: register,
    # return, go idle, and deliver the job's result as a notice.
    # The mounts come from the agent's own state: `tmp_path` is a real host
    # directory, and #79 took it off the introspection payload.
    # allowlist: snapshot — workspace_path + tmp_path
    state = :sys.get_state(pid, 1_000)
    key = {space_id, name}

    {:ok, _} =
      ShellCmd.execute("echo done", Mounts.from_agent(state), nil,
        background: true,
        agent_key: key,
        grace_ms: 0
      )

    [%{id: id}] = ShellJobs.list(key)
    MockClient.set_response("acknowledged")

    assert {:waiting, content} = Watch.register_shell_call(ctx(pid, name, space_id), id, 500)
    assert content =~ "Watching shell job #{id}"

    # The notice drains into a turn; that turn's own user-message broadcast is
    # the event that says the notice landed.
    assert_receive {:chat_message, {:user, _}}, 1_000
    assert Enum.any?(notices(pid), &(&1 =~ "exited with code 0"))

    await_idle(pid)
  end

  # A watch that reaches its `timeout` is a normal result, delivered as a
  # notice — never an error, and never a reason to keep the job: the job is
  # still running, and the caller is left registered for nothing.
  test "a shell watch that times out reports it and drops its registration", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    # allowlist: snapshot — workspace_path + tmp_path
    state = :sys.get_state(pid, 1_000)
    key = {space_id, name}

    {:ok, _} =
      ShellCmd.execute("sleep 30", Mounts.from_agent(state), nil,
        background: true,
        agent_key: key,
        grace_ms: 0
      )

    [%{id: id}] = ShellJobs.list(key)
    MockClient.set_response("acknowledged")

    _ = Watch.register_shell_call(ctx(pid, name, space_id), id, 10)

    # The timeout notice drains into a turn; that turn's own user-message
    # broadcast is the event that says it landed.
    assert_receive {:chat_message, {:user, _}}, 1_000

    assert Enum.any?(
             notices(pid),
             &(&1 =~ "Timed out after 10ms waiting for shell job #{id}")
           )

    # The watch unsubscribed on the way out, and the job is untouched.
    assert ShellJobs.waiters(id, 1_000) == []
    assert [%{id: ^id, status: :running}] = ShellJobs.list(key)

    await_idle(pid)
  end

  # A job the manager dropped with its agent (`ShellJobs.drop_agent/2` sends
  # `{:shell_job_gone, id}` to the job's waiters) must be reported as gone: not
  # as an exit, because no exit was observed and the log goes with the agent's
  # tmp directory, and not as the `:not_found` a *missing* job gets, because
  # this job existed and its owner stopped. The message is delivered to the
  # watcher task directly: `drop_agent/2`'s own send to a waiter is pinned in
  # `test/nest/sandbox/shell_jobs_test.exs`.
  test "the watcher reports a job whose agent stopped as gone, not as an exit", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    # allowlist: snapshot — workspace_path + tmp_path
    state = :sys.get_state(pid, 1_000)
    key = {space_id, name}

    {:ok, _} =
      ShellCmd.execute("sleep 30", Mounts.from_agent(state), nil,
        background: true,
        agent_key: key,
        grace_ms: 0
      )

    [%{id: id}] = ShellJobs.list(key)
    MockClient.set_response("acknowledged")

    _ = Watch.register_shell_call(ctx(pid, name, space_id), id, 5_000)

    assert [{_ref, %{pid: task}}] = Map.to_list(watchers(pid))
    send(task, {:shell_job_gone, id})

    # The notice drains into a turn; that turn's own user-message broadcast is
    # the event that says the notice landed. The full text is the pin: it is
    # the one wording that says the job is gone *because its agent stopped*,
    # neither an exit nor a missing job.
    assert_receive {:chat_message, {:user, _}}, 1_000

    assert Enum.any?(
             notices(pid),
             &(&1 =~ "Background job #{id} is gone: the agent that owned it stopped.")
           )

    assert watchers(pid) == %{}
    await_idle(pid)
  end
end
