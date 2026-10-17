defmodule Nest.Agents.Agent.IdleFenceTest do
  @moduledoc """
  The idle fence's own contract.

  `SubAgentToolsHelpers.await_idle/1` is decided by the arrival of the agent's
  `{:chat_status, %{name: name, status: "idle"}}` frame, so a fence whose frame
  never arrives has to time out. That is what makes it a fence rather than a
  check: the poll it replaced read `Machine.status_for/1`, and an agent that has
  never run a turn is idle from the moment it starts — so the poll would report
  success on an agent that broadcast nothing at all, and a broadcast regression
  could pass as a pass.

  The second test pins the other half: a fence matches the *first* queued `idle`
  frame, so a wait that spans more than one turn has to consume the turns that
  already ended — with `AgentTurnTestHelpers.await_delivery/1` or
  `statuses_until_idle/2` — before it fences. Otherwise it returns mid-turn, which
  is a wait that reports settled state it never observed.
  """

  use Nest.DataCase, async: true

  import Nest.Agents.AgentTestHelpers
  import Nest.Agents.AgentTurnTestHelpers
  import Nest.Agents.SubAgentToolsHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.LLM.MockClient

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  test "the fence is the idle frame: it fails without one, and passes with one" do
    {pid, name} = start_agent(%{model: %{name: "qwen3.5-plus"}})

    # No turn has run, so no `idle` frame has been broadcast — the agent is
    # nonetheless idle, which is exactly what a state-reading wait would report
    # as success. The fence must not: it burns its bound and fails as a missing
    # frame, not as a state that was wrong.
    #
    # The bound is 50 ms rather than the helper's 1000 ms default. The contract
    # is the *failure*, not the number, and this is the longest single test in
    # the suite: at 1000 ms it sets the suite's tail, which is not divided by
    # `max_cases` the way ordinary tests are.
    assert_raise ExUnit.AssertionError, ~r/no matching message after 50ms/, fn ->
      await_idle(name, 50)
    end

    # The same fence, on the frame the turn ends on: `Agent.chat/2` casts, so the
    # `idle` broadcast is the turn's last frame and every earlier frame of it
    # precedes this one in the mailbox.
    MockClient.set_response("hello")
    :ok = Agent.chat(pid, "hi")

    assert await_idle(name) == :ok
  end

  test "a wait for the settled turn consumes the turns that already ended" do
    {pid, name} = start_agent(%{model: %{name: "qwen3.5-plus"}})
    space_id = current_space_id()

    # Both turns below are fenced on the *space* topic's `{:agent_status, …}`
    # frame, which `Broadcasts.status/1` emits alongside the per-agent
    # `{:chat_status, …}` one. Fencing on the space frame is what leaves each
    # turn's per-agent `idle` frame queued — the stale frames a wait that matched
    # the mailbox's first `idle` would stop on.
    Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.space_topic(space_id))

    MockClient.set_response("one")
    :ok = Agent.chat(pid, "first")
    assert_receive {:agent_status, %{name: ^name, status: "idle"}}, 1_000

    MockClient.set_response("two")
    assert {:ok, :delivered} = Agent.deliver_internal(pid, "peer", "second", :notice)
    assert_receive {:agent_status, %{name: ^name, status: "idle"}}, 1_000

    # Both turns are over, so both of this agent's `idle` frames are queued: the
    # first turn's, then the delivery's. The wait has to consume the first (and
    # the delivery's own `{:user, …}` frame) and return on the second.
    notice = await_delivery("second")
    assert_receive {:chat_status, %{name: ^name, status: "idle"}}, 1_000

    # The frame the wait consumed is the delivery: a `:notice` renders bare (the
    # runtime speaking, not the peer), unlike the test's own chat above it.
    refute notice =~ "Message from agent"

    # The pin: a wait that stopped on the first turn's `idle` frame would leave
    # the delivery's `idle` frame here, unconsumed — and would have reported a
    # settled state it never observed. Nothing else can broadcast one (the agent
    # has no children, and these mocked responses carry no usage), so this is
    # decided by what the wait consumed, not by the clock.
    refute_received {:chat_status, %{name: ^name, status: "idle"}}
    assert Agent.get_public_info(pid, 1_000).status == :idle
  end
end
