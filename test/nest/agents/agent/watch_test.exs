defmodule Nest.Agents.Agent.WatchTest do
  @moduledoc """
  Coverage for the non-blocking waits (issues #54 + #62): registration,
  the bare notice, the satisfied-watch suppression, and watcher lifetime.

  The tool is driven directly with a `ctx` carrying the real agent pid (the
  way `ToolLoop.execute/3` is called in production) so the watch is registered
  on a real agent without running a whole turn; the listing is stubbed to drive
  the watcher's status reads.
  """
  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.Agent.Watch
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
        %ToolCall{id: "w1", name: "agents-wait-for-idle", arguments: args}
      ])

    result
  end

  defp agent(name, status), do: %{name: name, status: status}

  # Drive `list_agents_info_for_space/1` from a FIFO of snapshots; the last
  # sticks. The watcher reads the listing once up front and again on each
  # slice, so a frame can flip a target busy → idle. `Elixir.Agent` is the
  # stdlib queue process — `Agent` here is `Nest.Agents.Agent`.
  defp stub_listing(frames) do
    id = {:watch_listing, System.unique_integer([:positive])}
    queue = start_supervised!({Elixir.Agent, fn -> frames end}, id: id)

    Mimic.stub(Nest.Agents, :list_agents_info_for_space, fn _space_id ->
      Elixir.Agent.get_and_update(queue, &next_listing/1)
    end)
  end

  defp next_listing([last]), do: {last, [last]}
  defp next_listing([head | rest]), do: {head, rest}

  defp watchers(pid), do: :sys.get_state(pid).live.watches

  # The notice drains into a turn; wait for it to finish so the
  # test-lifecycle check sees an idle agent.
  defp await_idle(pid) do
    assert Eventually.eventually(
             fn -> Machine.status_for(:sys.get_state(pid).live.machine) == :idle end,
             timeout: 500
           )
  end

  defp set_busy(pid) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{state.live | machine: Machine.status_to_machine(state.live.machine, :streaming)}
      }
    end)
  end

  defp reset_to_idle(pid) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{state.live | machine: Machine.status_to_machine(state.live.machine, :idle)}
      }
    end)
  end

  defp notices(pid) do
    :sys.get_state(pid).chat_state.messages
    |> Enum.flat_map(fn
      {:user, %{parts: parts}} -> Enum.map(parts, & &1.text)
      _ -> []
    end)
  end

  test "registers and returns immediately, leaving the agent idle", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    stub_listing([[agent(name, :idle), agent("bob", :streaming)]])

    result = wait(pid, name, space_id, %{"names" => ["bob"]})

    assert %ToolResult{name: "agents-wait-for-idle", is_error: false, content: content} = result
    assert content =~ "Watching"
    assert content =~ "bob"

    # A watch is registered, and the agent never left idle (issue #54): the
    # tool returned without blocking a turn.
    assert map_size(watchers(pid)) == 1
    assert Machine.status_for(:sys.get_state(pid).live.machine) == :idle
  end

  test "an already-idle-only wait registers nothing", %{pid: pid, name: name, space_id: space_id} do
    stub_listing([[agent(name, :idle), agent("bob", :idle)]])

    result = wait(pid, name, space_id, %{"names" => ["bob"]})

    assert %ToolResult{is_error: false, content: content} = result
    assert content == "All agents are already idle: bob."
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
    assert %ToolResult{is_error: false} = wait(pid, name, space_id, %{"names" => ["bob"]})

    # The notice is delivered while the agent is idle, so it drains and starts
    # a turn with the bare synchronisation text — never a payload.
    assert Eventually.eventually(
             fn -> Enum.any?(notices(pid), &(&1 =~ "Agents now idle")) end,
             timeout: 500
           )

    assert Enum.any?(notices(pid), &(&1 =~ "bob"))
    assert watchers(pid) == %{}
    await_idle(pid)
  end

  test "a timeout delivers a distinguishable bare notice", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    stub_listing([[agent(name, :idle), agent("bob", :streaming)]])
    MockClient.set_response("acknowledged")

    assert %ToolResult{is_error: false} =
             wait(pid, name, space_id, %{"names" => ["bob"], "timeout" => 50})

    assert Eventually.eventually(
             fn -> Enum.any?(notices(pid), &(&1 =~ "Timed out after 50ms")) end,
             timeout: 500
           )

    await_idle(pid)
  end

  test "a delivery from the watched agent satisfies the watch", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    stub_listing([[agent(name, :idle), agent("bob", :streaming)]])
    assert %ToolResult{is_error: false} = wait(pid, name, space_id, %{"names" => ["bob"]})

    assert [{_ref, %{satisfied: false}}] = Map.to_list(watchers(pid))

    MockClient.set_response("acknowledged")
    assert {:ok, :delivered} = Agent.deliver_message(pid, "bob", "the report", :agent)

    assert [{_ref, %{satisfied: true}}] = Map.to_list(watchers(pid))
    await_idle(pid)
  end

  test "a satisfied watch is skipped, never delivered" do
    # Pure: a satisfied watch is dropped without touching the inbox, so the
    # caller that the body already woke is not woken a second time.
    ref = make_ref()

    state = %Agent{
      live: %Agent.ChatState.Live{watches: %{ref => %{pid: nil, spec: nil, satisfied: true}}}
    }

    assert {%Agent{live: %Agent.ChatState.Live{watches: %{}}}, :skipped} =
             Watch.fired(state, ref, "notice")
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
    assert %ToolResult{is_error: false} = wait(pid, name, space_id, %{"names" => ["bob"]})

    [{_ref, %{pid: task}}] = Map.to_list(watchers(pid))
    mref = Process.monitor(task)

    state = :sys.get_state(pid)
    assert Watch.stop_all(state).live.watches == %{}
    assert_receive {:DOWN, ^mref, :process, ^task, _reason}, 500
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

    {:ok, task} = Watch.start(caller, ref, {:agent_idle, 1, ["bob"], 60_000, false})
    mref = Process.monitor(task)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^mref, :process, ^task, _reason}, 500
  end

  test "stopping the agent kills its watchers", %{pid: pid, name: name, space_id: space_id} do
    # The agent's `terminate/2` kills every outstanding watcher, so a stopped
    # agent never leaves one behind. Trap the link exit the helper makes so the
    # stop does not take the test process with it.
    Process.flag(:trap_exit, true)
    stub_listing([[agent(name, :idle), agent("bob", :streaming)]])
    assert %ToolResult{is_error: false} = wait(pid, name, space_id, %{"names" => ["bob"]})

    [{_ref, %{pid: task}}] = Map.to_list(watchers(pid))
    mref = Process.monitor(task)

    _ = Supervisor.stop_agent(space_id, name)

    assert_receive {:DOWN, ^mref, :process, ^task, _reason}, 500
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
      # the watcher's initial read: still busy
      [agent(name, :idle), agent("bob", :streaming)],
      # the watcher's recheck: bob is idle now, so it fires
      [agent(name, :idle), agent("bob", :idle)]
    ])

    MockClient.set_response("read the report")
    assert %ToolResult{is_error: false} = wait(pid, name, space_id, %{"names" => ["bob"]})

    # The target's completion, delivered the way the runtime delivers a child's
    # (`Inbox.enqueue_internal/5`, kind `:agent`). The caller is idle, so this
    # starts its turn.
    assert {:ok, :delivered} = Agent.deliver_internal(pid, "bob", "the report", :agent)

    # The watcher fires within a slice and finds the watch satisfied: the caller
    # is not woken a second time. `fired/3` unregisters before delivering, so
    # assert the wake itself too — exactly one user turn (the report), no bare
    # notice in the transcript or still queued.
    assert Eventually.eventually(fn -> watchers(pid) == %{} end, timeout: 500)
    await_idle(pid)

    texts = notices(pid)
    assert length(texts) == 1
    assert Enum.count(texts, &(&1 =~ "the report")) == 1
    refute Enum.any?(texts, &(&1 =~ "Agents now idle"))
    refute Enum.any?(:sys.get_state(pid).live.inbox, &(&1.kind == :notice))
  end

  # The second variant: the caller is busy when the report arrives, so it
  # queues; the watch fires satisfied (no bare notice), and the caller pulls the
  # body mid-turn with `agents-last-message`, consuming it so the drain cannot
  # deliver it again.
  test "a mid-turn caller fetches the queued delivery once", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    stub_listing([
      [agent(name, :idle), agent("bob", :streaming)],
      [agent(name, :idle), agent("bob", :streaming)],
      [agent(name, :idle), agent("bob", :idle)]
    ])

    assert %ToolResult{is_error: false} = wait(pid, name, space_id, %{"names" => ["bob"]})

    # The caller is busy, so the report queues rather than starting a turn.
    set_busy(pid)
    assert {:ok, :queued} = Agent.deliver_internal(pid, "bob", "the report", :agent)

    # The watch fires satisfied: no bare notice.
    assert Eventually.eventually(fn -> watchers(pid) == %{} end, timeout: 500)

    [%ToolResult{content: content, is_error: false}] =
      ToolLoop.execute(ctx(pid, name, space_id), nil, [
        %ToolCall{id: "m1", name: "agents-last-message", arguments: %{"name" => "bob"}}
      ])

    assert content =~ "the report"
    assert [%{retrieved: true}] = :sys.get_state(pid).live.inbox
    reset_to_idle(pid)
  end

  test "shell-wait registers and the notice carries the job output", %{
    pid: pid,
    name: name,
    space_id: space_id
  } do
    # `shell-wait` follows the same shape as `agents-wait-for-idle`: register,
    # return, go idle, and deliver the job's result as a notice.
    state = :sys.get_state(pid)
    key = {space_id, name}

    {:ok, _} =
      ShellCmd.execute("echo done", Mounts.new(state.workspace_path, state.tmp_path), nil,
        background: true,
        agent_key: key,
        grace_ms: 0
      )

    [%{id: id}] = ShellJobs.list(key)
    MockClient.set_response("acknowledged")

    assert {:ok, content} = Watch.register_shell_call(ctx(pid, name, space_id), id, 500)
    assert content =~ "Watching background job #{id}"

    assert Eventually.eventually(
             fn -> Enum.any?(notices(pid), &(&1 =~ "exited with code 0")) end,
             timeout: 2_000
           )

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
    state = :sys.get_state(pid)
    key = {space_id, name}

    {:ok, _} =
      ShellCmd.execute("sleep 30", Mounts.new(state.workspace_path, state.tmp_path), nil,
        background: true,
        agent_key: key,
        grace_ms: 0
      )

    [%{id: id}] = ShellJobs.list(key)
    MockClient.set_response("acknowledged")

    assert {:ok, content} = Watch.register_shell_call(ctx(pid, name, space_id), id, 5_000)
    assert content =~ "Watching background job #{id}"

    assert [{_ref, %{pid: task}}] = Map.to_list(watchers(pid))
    send(task, {:shell_job_gone, id})

    assert Eventually.eventually(
             fn -> Enum.any?(notices(pid), &(&1 =~ "the agent that owned it stopped")) end,
             timeout: 500
           )

    texts = notices(pid)
    assert Enum.any?(texts, &(&1 =~ "Background job #{id} is gone"))
    refute Enum.any?(texts, &(&1 =~ "exited with code"))
    refute Enum.any?(texts, &(&1 =~ "no longer exists"))
    assert watchers(pid) == %{}
    await_idle(pid)
  end

  test "the stop transition emits the watcher kill", %{pid: pid} do
    # The action is emitted by the pure stop; `Turn.Executor`'s clause reads
    # `live.watches`. Asserting the action here keeps the Stop contract pinned
    # without driving a whole turn.
    state = :sys.get_state(pid)
    machine = Machine.status_to_machine(state.live.machine, :streaming)
    {:ok, actions, _machine} = Machine.step(machine, {:stop, nil})

    assert {:stop_watchers} in actions
  end
end
