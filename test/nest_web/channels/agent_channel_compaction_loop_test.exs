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

  The `chat:message` refusal in this status is the shared
  `@broken_statuses` clause, pinned with a real agent in
  `NestWeb.AgentChannelNeedsRepairTest` and
  `NestWeb.AgentChannelChatTest`; `:compaction_loop_detected`'s
  membership in `Machine.blocked_phases/0` is pinned in
  `Nest.Agents.Agent.InboxTest`.
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
  defp replace_state(pid, fun), do: :sys.replace_state(pid, fun, 1_000)

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

    # One exact payload: the handler forwards the broadcast verbatim, so a
    # dropped or altered field — or one the channel invented — fails here.
    # Top-level keys stay atoms: the test transport delivers the term the
    # channel pushed, without a JSON round-trip (the broadcast's shape is
    # `Broadcasts.compaction_loop/6`'s).
    assert_push "chat:compaction-loop", payload, 200

    assert payload == %{
             content:
               "compaction isn't reducing the conversation — start a new session, change model, or clear history",
             attempt_count: 3,
             max_attempts: 3
           }
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
            | machine: Machine.status_to_machine(cs.machine, :compaction_loop_detected)
          }
      }
    end)

    ref = push(socket, "chat:loop-detected-ok", %{})
    assert_reply ref, :ok, %{}, 1_000

    # `:ok` alone cannot fail: `Callbacks.handle_call(:compaction_loop_detected_ok, …)`
    # answers `:ok` from the wrong-status branch too, without settling anything.
    # The status leaving `:compaction_loop_detected` is the observable that
    # proves the ack ran. The `loop_count` reset that comes with it is the
    # machine's, pinned in `MachineBoundaryDeliveryTest`.
    # allowlist: snapshot — status
    state = :sys.get_state(agent_pid, 1_000)

    assert Machine.status_for(state.live.machine) == :idle
  end
end
