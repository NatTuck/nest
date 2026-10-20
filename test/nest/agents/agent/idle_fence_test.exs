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

  test "the fence is the idle frame: a frame that never arrives fails the wait" do
    {_pid, name} = start_agent(%{model: %{name: "qwen3.5-plus"}})

    # No turn has run, so no `idle` frame has been broadcast — the agent is
    # nonetheless idle, which is exactly what a state-reading wait would report
    # as success. The fence must not: it burns its bound and fails as a missing
    # frame, not as a state that was wrong. (The passing half of this fence is
    # every `await_idle/1` call site in the suite, each of which would raise here
    # if the frame the turn ends on stopped matching; this test owns the
    # failure.)
    #
    # The bound is 50 ms rather than the helper's 1000 ms default: the contract
    # is the *failure*, not the number, so the wait is as short as the raise
    # needs.
    assert_raise ExUnit.AssertionError, ~r/no matching message after 50ms/, fn ->
      await_idle(name, 50)
    end
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
    # The delivery's own turn ending below is the fence for this call; the
    # `:delivered` / `:queued` disposition it returns is `InboxTest`'s contract.
    Agent.deliver_internal(pid, "peer", "second", :runtime)
    assert_receive {:agent_status, %{name: ^name, status: "idle"}}, 1_000

    # Both turns are over, so both of this agent's `idle` frames are queued: the
    # first turn's, then the delivery's. The wait has to consume the first (and
    # the delivery's own `{:user, …}` frame) and return on the second.
    await_delivery("second")
    assert_receive {:chat_status, %{name: ^name, status: "idle"}}, 1_000

    # The pin: a wait that stopped on the first turn's `idle` frame would leave
    # the delivery's `idle` frame here, unconsumed — and would have reported a
    # settled state it never observed. Nothing else can broadcast one (the agent
    # has no children, and these mocked responses carry no usage), so this is
    # decided by what the wait consumed, not by the clock.
    refute_received {:chat_status, %{name: ^name, status: "idle"}}
  end
end
