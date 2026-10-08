defmodule Nest.Agents.Agent.ToolLoopAsyncTest do
  @moduledoc """
  Coverage for the `async: true` modes of `agents-spawn` and
  `agents-query`.

  With `async: true` the tool call returns immediately and the outcome is
  delivered to the calling agent's own inbox as a message, exactly as if a
  peer had `agents-send`-ed it, with a one-line note naming the call. The
  wait runs in a supervised `Nest.Agents.Agent.AsyncWaiter` task, never in
  the calling agent's GenServer.

  The tool dispatch runs in the test process (exactly as the turn's tool
  worker would), so the waiter is a `Task.Supervisor` child whose
  `$callers` include this test — `find_waiter_task/0` uses that to hold
  onto it and prove it finishes before the test does.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents.Agent.AsyncWaiter
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Mimic.copy(Nest.Agents)

    {:ok, coordinator_vid: upsert_vocation(["context", "agents"]), peer_slug: peer_slug()}
  end

  test "async agents-spawn returns immediately and later delivers a noted result", %{
    coordinator_vid: vid,
    peer_slug: slug
  } do
    {coordinator_pid, coordinator_name} = start_coordinator(vid)
    child_name = "async-child-#{System.unique_integer([:positive])}"

    # The child's chat is short-circuited; the test drives its completion
    # below. The coordinator itself answers the delivery turn.
    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _prompt -> :ok end)
    Mimic.allow(Nest.Agents, self(), coordinator_pid)
    MockClient.set_response("coordinator handled the spawn result")

    [result] =
      ToolLoop.execute(ctx(coordinator_pid, coordinator_name), nil, [
        spawn_call(%{
          "name" => child_name,
          "vocation" => slug,
          "query" => "do the thing",
          "async" => true
        })
      ])

    # The call returned immediately with a confirmation — no child
    # response was awaited.
    assert %ToolResult{name: "agents-spawn", is_error: false, content: confirmation} = result
    assert confirmation =~ child_name
    assert confirmation =~ "asynchronously"
    assert delivered_notes(coordinator_pid, "[agents-spawn result]") == []

    waiter = find_waiter_task()
    assert is_pid(waiter)
    waiter_ref = Process.monitor(waiter)

    cast_child_completed(coordinator_pid, child_name, "the async answer")

    # Exactly one message is delivered.
    assert [note] = await_delivery(coordinator_pid, "[agents-spawn result]")
    assert note =~ "the async answer"
    # The message names the child it came from.
    assert note =~ child_name

    assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, :normal}, 500
  end

  test "async agents-spawn with an invalid vocation errors immediately and leaves no waiter", %{
    coordinator_vid: vid
  } do
    {coordinator_pid, coordinator_name} = start_coordinator(vid)
    missing_slug = "no-such-vocation-#{System.unique_integer([:positive])}"

    {results, log} =
      with_log(fn ->
        ToolLoop.execute(ctx(coordinator_pid, coordinator_name), nil, [
          spawn_call(%{
            "name" => "never-spawns-#{System.unique_integer([:positive])}",
            "vocation" => missing_slug,
            "query" => "hi",
            "async" => true
          })
        ])
      end)

    assert [%ToolResult{name: "agents-spawn", is_error: true, content: content}] = results
    assert content =~ missing_slug
    assert log =~ "is_error=true tool result"

    # The worker abandons the waiter, so it does not linger waiting for a
    # result that can never arrive.
    assert Eventually.eventually(fn -> find_waiter_task() == nil end, timeout: 500)
  end

  test "the spawn waiter delivers every outcome with the right note and body", %{
    coordinator_vid: vid
  } do
    {parent, name} = start_coordinator(vid)
    MockClient.set_response("after empty")
    MockClient.set_response("after error")
    MockClient.set_response("after raced")
    MockClient.set_response("after timeout")

    # A child that produced no text is a failure, not a silent empty result.
    run_spawn_waiter(parent, name, [
      {:spawn_agent_go, "child-empty"},
      {:spawn_agent_result, "child-empty", ""}
    ])

    assert [empty] = await_delivery(parent, "without producing any text")
    assert empty =~ "[agents-spawn failed]"
    assert empty =~ "child-empty"

    # A child that failed carries the failure reason.
    run_spawn_waiter(parent, name, [
      {:spawn_agent_go, "child-error"},
      {:spawn_agent_error, "child-error", :boom}
    ])

    assert [error] = await_delivery(parent, "failed: :boom")
    assert error =~ "[agents-spawn failed]"
    assert error =~ "child-error"

    # The outcome can beat the go signal — the worker died (or its spawn
    # call timed out) after the child was spawned. It must still be
    # delivered, not discarded.
    run_spawn_waiter(parent, name, [{:spawn_agent_result, "child-raced", "raced answer"}])

    assert [raced] = await_delivery(parent, "raced answer")
    assert raced =~ "[agents-spawn result]"
    assert raced =~ "child-raced"

    # No result at all: the single deadline expires and a timeout note is
    # delivered (a normal result, not an error).
    run_spawn_waiter(parent, name, [{:spawn_agent_go, "child-slow"}], 20)

    assert [timed_out] = await_delivery(parent, "did not complete in time")
    assert timed_out =~ "[agents-spawn timed out]"
    assert timed_out =~ "child-slow"
  end

  test "async agents-query delivers a noted result", %{coordinator_vid: vid, peer_slug: slug} do
    {coordinator_pid, coordinator_name} = start_coordinator(vid)
    space_id = AgentTestHelpers.current_space_id()
    peer_name = "async-peer-#{System.unique_integer([:positive])}"

    start_mocked_peer(space_id, coordinator_pid, peer_name, slug, "the peer answer")
    MockClient.set_response("coordinator handled the query result")

    [result] =
      ToolLoop.execute(ctx(coordinator_pid, coordinator_name), nil, [
        %ToolCall{
          id: "query-async-1",
          name: "agents-query",
          arguments: %{"name" => peer_name, "prompt" => "hello?", "async" => true}
        }
      ])

    assert %ToolResult{name: "agents-query", is_error: false, content: confirmation} = result
    assert confirmation =~ peer_name
    assert confirmation =~ "asynchronously"

    assert [note] = await_delivery(coordinator_pid, "[agents-query result]")
    assert note =~ "the peer answer"
    assert note =~ peer_name

    # The waiter has delivered its one result and exited.
    assert Eventually.eventually(fn -> find_waiter_task() == nil end, timeout: 500)
  end

  test "an async query that times out delivers a noted timeout message as a normal result", %{
    coordinator_vid: vid
  } do
    {coordinator_pid, coordinator_name} = start_coordinator(vid)

    # The peer exists (its message read succeeds) but never goes idle.
    Mimic.stub(Nest.Agents, :get_messages, fn _space_id, _name -> {:ok, []} end)
    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _prompt -> :ok end)
    MockClient.set_response("coordinator handled the timeout")

    log =
      capture_log(fn ->
        [result] =
          ToolLoop.execute(ctx(coordinator_pid, coordinator_name), nil, [
            %ToolCall{
              id: "query-timeout-1",
              name: "agents-query",
              arguments: %{
                "name" => "slow-peer",
                "prompt" => "hello?",
                "async" => true,
                "timeout" => 1
              }
            }
          ])

        # A timeout is a normal result, never an error: the immediate tool
        # result is the confirmation, not a failure.
        assert %ToolResult{name: "agents-query", is_error: false, content: confirmation} = result
        assert confirmation =~ "asynchronously"

        assert [note] = await_delivery(coordinator_pid, "[agents-query timed out]")
        assert note =~ "timed out after 1ms"
      end)

    assert log =~ "agents-query: target did not go idle within 1ms"
  end

  test "the query waiter delivers a peer failure with the failed note", %{
    coordinator_vid: vid
  } do
    {parent, name} = start_coordinator(vid)

    # The target cannot be read: the waiter delivers a failure, not a
    # crash.
    Mimic.stub(Nest.Agents, :get_messages, fn _space_id, _name -> {:error, :not_found} end)
    MockClient.set_response("after query failure")

    {:ok, waiter} =
      AsyncWaiter.start_query(parent, ctx(parent, name), %ToolCall{}, "ghost", "hi", 60_000)

    waiter_ref = Process.monitor(waiter)
    assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, :normal}, 500

    assert [failed] = await_delivery(parent, "not found in this space")
    assert failed =~ "[agents-query failed]"
    assert failed =~ "ghost"
  end

  test "a refused delivery is logged at warning level and the waiter still exits", %{
    coordinator_vid: vid
  } do
    {parent, name} = start_coordinator(vid)
    # A broken target status makes `Inbox.handle_delivery/3` refuse.
    set_status(parent, :needs_repair)

    log =
      capture_log(fn ->
        {:ok, waiter} = AsyncWaiter.start_spawn(parent, ctx(parent, name), %ToolCall{}, 60_000)

        waiter_ref = Process.monitor(waiter)
        send(waiter, {:spawn_agent_go, "child-refused"})
        send(waiter, {:spawn_agent_result, "child-refused", "answer"})

        assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, :normal}, 500
      end)

    assert log =~ "could not be delivered"
    assert log =~ "needs_repair"
  end

  test "a waiter exits quietly when its calling agent dies" do
    # A live process that never does anything: killing it is the only
    # event it ever sees.
    parent = idle_process()
    {:ok, spawn_waiter} = AsyncWaiter.start_spawn(parent, %{}, %ToolCall{}, 60_000)
    spawn_ref = Process.monitor(spawn_waiter)
    Process.exit(parent, :kill)

    # `:normal` is exactly what suppresses the Task.Supervisor's crash
    # report; an abnormal exit would log one.
    assert_receive {:DOWN, ^spawn_ref, :process, ^spawn_waiter, :normal}, 500

    # The query waiter monitors the same way, from inside its wait loop.
    Mimic.stub(Nest.Agents, :get_messages, fn _space_id, _name -> {:ok, []} end)
    Mimic.stub(Nest.Agents, :chat, fn _space_id, _name, _prompt -> :ok end)

    peer_parent = idle_process()

    {:ok, query_waiter} =
      AsyncWaiter.start_query(peer_parent, %{space_id: 1}, %ToolCall{}, "peer", "hi", 60_000)

    query_ref = Process.monitor(query_waiter)
    Process.exit(peer_parent, :kill)

    assert_receive {:DOWN, ^query_ref, :process, ^query_waiter, :normal}, 500
  end

  # -- helpers --

  defp start_coordinator(vid) do
    AgentTestHelpers.start_agent(%{
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      vocation_id: vid
    })
  end

  # A live process that does nothing until killed.
  defp idle_process do
    spawn(fn ->
      receive do
        :never -> :ok
      end
    end)
  end

  defp ctx(coordinator_pid, coordinator_name) do
    %{
      agent_pid: coordinator_pid,
      agent_name: coordinator_name,
      space_id: AgentTestHelpers.current_space_id(),
      context_limit: 100_000,
      messages: []
    }
  end

  defp spawn_call(arguments) do
    %ToolCall{id: "spawn-async-1", name: "agents-spawn", arguments: arguments}
  end

  # Start a spawn waiter, hand it the given messages, and prove it exits
  # normally before the test ends.
  defp run_spawn_waiter(parent_pid, parent_name, messages, timeout \\ 60_000) do
    {:ok, waiter} =
      AsyncWaiter.start_spawn(parent_pid, ctx(parent_pid, parent_name), %ToolCall{}, timeout)

    waiter_ref = Process.monitor(waiter)
    Enum.each(messages, &send(waiter, &1))
    assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, :normal}, 500
  end

  # Cast `:child_completed` to the coordinator, mimicking what an idle
  # child sends in production. The coordinator forwards
  # `:spawn_agent_result` to the waiter (the tracked worker pid).
  defp cast_child_completed(coordinator_pid, child_name, response) do
    usage = %{
      input_tokens: 0,
      output_tokens: 7,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 7,
      last_output: 7,
      total_input_tokens: 0,
      total_cache_read_input_tokens: 0,
      total_cache_creation_input_tokens: 0,
      context_input_tokens: 0
    }

    GenServer.cast(coordinator_pid, {:child_completed, child_name, response, usage})
  end

  # The waiter is the only Task under `Nest.Agents.TaskSupervisor` whose
  # `$callers` include this test (it was started by the tool dispatch
  # running here). Distinguishes it from concurrent tests' tasks and from
  # the agents' HTTP workers (whose callers are the agent pids).
  defp find_waiter_task do
    Nest.Agents.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.find(&spawned_by_this_test?/1)
  end

  defp spawned_by_this_test?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> self() in Keyword.get(dict, :"$callers", [])
      _ -> false
    end
  end

  # Wait until the coordinator has received the noted message(s) AND
  # finished the turn it started. Both must hold before the test ends so
  # no background process touches the sandbox after it is checked in.
  # Returns every matching message so a caller can assert there is
  # *exactly one* (a duplicate delivery must fail the test).
  defp await_delivery(coordinator_pid, note) do
    Eventually.eventually(fn -> notes_when_idle(coordinator_pid, note) end, timeout: 500)
  end

  defp notes_when_idle(coordinator_pid, note) do
    state = :sys.get_state(coordinator_pid)
    status = Machine.status_for(state.live.machine)
    notes = delivered_notes(state.chat_state.messages, note)

    case {status, notes} do
      {:idle, [_ | _] = notes} -> notes
      _ -> nil
    end
  end

  defp delivered_notes(coordinator_pid, note) when is_pid(coordinator_pid) do
    delivered_notes(:sys.get_state(coordinator_pid).chat_state.messages, note)
  end

  defp delivered_notes(messages, note) do
    messages
    |> Enum.flat_map(&user_texts/1)
    |> Enum.filter(&(&1 =~ note))
  end

  defp user_texts({:user, %{parts: parts}}) do
    for %Part.Text{text: text} <- parts, do: text
  end

  defp user_texts(_other), do: []

  # Put the agent into an arbitrary machine status (e.g. a broken one), as
  # `InboxTest` does.
  defp set_status(pid, status) do
    :sys.replace_state(pid, fn state ->
      %{
        state
        | live: %{state.live | machine: Machine.status_to_machine(state.live.machine, status)}
      }
    end)
  end

  # An independent peer, wired to MockClient so the waiter's query gets a
  # deterministic reply.
  defp start_mocked_peer(space_id, coordinator_pid, name, slug, response) do
    parent_state = :sys.get_state(coordinator_pid)

    assert {:ok, ^name} = Supervisor.spawn_agent_in_space(parent_state, name, slug)

    {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)
    Sandbox.allow(Nest.Repo, self(), pid)

    :sys.replace_state(pid, fn st ->
      %{st | client_config: %{st.client_config | client: MockClient}}
    end)

    MockClient.start_link(pid)
    MockClient.put_pending(pid, {:text, response})

    on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)
  end

  defp upsert_vocation(tools) do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "AsyncTools #{System.unique_integer([:positive])}",
        description: "Coordinator with sub-agent tools",
        system_prompt: "Coordinate specialists in this space.",
        tools: tools,
        modes: %{
          "chat" => %{
            "description" => "Chat",
            "caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}
          }
        }
      })

    vid
  end

  defp peer_slug do
    {:ok, %Vocations.Vocation{slug: slug}} =
      Vocations.upsert_vocation(%{
        name: "AsyncPeer #{System.unique_integer([:positive])}",
        description: "A peer specialist",
        system_prompt: "You are a peer.",
        tools: ["context"],
        modes: %{}
      })

    slug
  end
end
