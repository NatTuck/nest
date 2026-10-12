defmodule Nest.Agents.Agent.BroadcastsStatusTest do
  @moduledoc """
  `Broadcasts.status/1` must emit the sidebar's space-scoped
  `{:agent_status, …}` frame alongside the per-agent `{:chat_status, …}`
  one. The per-agent topic only reaches clients *viewing* the agent, so
  without the space frame a client never learns that another agent went
  busy (#53).
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.LLM.MockClient

  import Nest.Agents.AgentTestHelpers

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  test "emits the space-scoped status frame alongside the per-agent one" do
    {pid, name} = start_agent()
    state = :sys.get_state(pid, 500)

    Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.topic(state.space_id, name))
    Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.space_topic(state.space_id))

    Broadcasts.status(state)

    assert_receive {:chat_status, payload}, 500
    assert_receive {:agent_status, frame}, 500

    assert frame.space_id == state.space_id
    assert frame.name == name
    # Pin the literal status rather than parity with the per-agent payload:
    # parity alone would also hold if both frames carried the wrong value.
    assert frame.status == to_string(Machine.status_for(state.live.machine))
    assert frame.status == payload.status
  end
end
