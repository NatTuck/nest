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
  alias Nest.Agents.Agent.Machine
  use NestWeb.AgentChannelTestHelpers

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Supervisor

  # `:sys.replace_state/3` with an explicit timeout: OTP's default is 5000 ms,
  # well over both this suite's 500 ms test bound and ExUnit's 2000 ms per-test
  # ceiling, so a wedged server surfaces as the stuck call it is rather than as
  # a test timeout (#21).
  defp replace_state(pid, fun), do: :sys.replace_state(pid, fun, 500)

  setup :verify_on_exit!

  test "channel pushes chat:compaction-loop to the socket on a chat_compaction_loop broadcast", %{
    agent_id: agent_id,
    space_id: space_id
  } do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "agent:#{space_id}:#{agent_id}",
      {:chat_compaction_loop,
       %{
         content:
           "compaction isn't reducing the conversation — start a new session, change model, or clear history",
         attempt_count: 3,
         max_attempts: 3
       }}
    )

    assert_push "chat:compaction-loop", payload, 200
    assert payload.content =~ "compaction isn't reducing"
    assert payload.attempt_count == 3
    assert payload.max_attempts == 3
  end

  test "chat:message is rejected while agent is in :compaction_loop_detected status", %{
    socket: socket,
    agent_id: agent_id,
    space_id: space_id
  } do
    {:ok, agent_pid} = Supervisor.get_agent(space_id, agent_id)

    replace_state(agent_pid, fn %Agent{live: cs} = state ->
      %{
        state
        | live: %{
            cs
            | machine: Machine.status_to_machine(cs.machine, :compaction_loop_detected)
          }
      }
    end)

    ref = push(socket, "chat:message", %{"content" => "trying to send", "mode" => "chat"})

    # `assert_reply/3` defaults to a 100ms receive timeout; the reply
    # requires a channel→Agent cross-process round-trip, which can
    # exceed that under parallel test load. See the same note in
    # `lobby_channel_change_model_test.exs`.
    assert_reply ref, :error, %{"reason" => "agent_status_compaction_loop_detected"}, 1_000
  end

  test "chat:loop-detected-ok invokes Agent.compaction_loop_detected_ok and transitions to :idle",
       %{
         socket: socket,
         agent_id: id,
         space_id: space_id
       } do
    {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

    replace_state(agent_pid, fn %Agent{live: cs} = state ->
      %{
        state
        | live: %{
            cs
            | machine: %{
                Machine.status_to_machine(cs.machine, :compaction_loop_detected)
                | loop_count: 4
              }
          }
      }
    end)

    ref = push(socket, "chat:loop-detected-ok", %{})
    assert_reply ref, :ok, %{}, 1_000

    # Status should transition back to :idle after the OK click,
    # and the counter resets to 0.
    state = :sys.get_state(agent_pid, 500)

    assert Machine.status_for(state.live.machine) == :idle
    assert state.live.machine.loop_count == 0
  end
end
