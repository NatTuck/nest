defmodule NestWeb.AgentChannelCompactionLoopTest do
  @moduledoc """
  Tests for the `:compaction_loop_detected` failure state and
  its OK-button flow.

  Pins the channel-side behavior:

    * `chat:compaction-loop` PubSub broadcasts are forwarded as
      `chat:compaction-loop` pushes to the socket (so the JS
      side can render the OK button).
    * `chat:loop-detected-ok` from the JS side invokes
      `Agents.compaction_loop_detected_ok/1`, which clears the
      `:compaction_loop_detected` status on the agent.
    * `chat:message` is rejected when the agent is in
      `:compaction_loop_detected` status (frozen state, OK
      required to resume).
  """

  use NestWeb.ChannelCase, async: true
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Supervisor

  setup :verify_on_exit!

  test "channel pushes chat:compaction-loop to the socket on a chat_compaction_loop broadcast", %{
    agent_id: agent_id
  } do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{agent_id}",
      {:chat_compaction_loop,
       %{
         content:
           "compaction isn't reducing the conversation — start a new session, change model, or clear history"
       }}
    )

    assert_push "chat:compaction-loop", payload, 200
    assert payload.content =~ "compaction isn't reducing"
  end

  test "chat:message is rejected while agent is in :compaction_loop_detected status", %{
    socket: socket,
    agent_id: agent_id
  } do
    {:ok, agent_pid} = Supervisor.get_agent(agent_id)

    :sys.replace_state(agent_pid, fn %Agent{chat_state: cs} = state ->
      %{state | chat_state: %{cs | status: :compaction_loop_detected}}
    end)

    ref = push(socket, "chat:message", %{"content" => "trying to send", "mode" => "chat"})
    assert_reply ref, :error, %{"reason" => "agent_status_compaction_loop_detected"}
  end

  test "chat:loop-detected-ok invokes Agent.compaction_loop_detected_ok and transitions to :idle",
       %{
         socket: socket,
         agent_id: id
       } do
    {:ok, agent_pid} = Supervisor.get_agent(id)

    :sys.replace_state(agent_pid, fn %Agent{chat_state: cs} = state ->
      %{
        state
        | chat_state: %{cs | status: :compaction_loop_detected, consecutive_compaction_count: 4}
      }
    end)

    ref = push(socket, "chat:loop-detected-ok", %{})
    assert_reply ref, :ok, %{}

    # Status should transition back to :idle after the OK click,
    # and the counter resets to 0.
    state = :sys.get_state(agent_pid)

    assert state.chat_state.status == :idle
    assert state.chat_state.consecutive_compaction_count == 0
  end
end
