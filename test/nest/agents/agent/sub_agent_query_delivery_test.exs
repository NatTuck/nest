defmodule Nest.Agents.Agent.SubAgentQueryDeliveryTest do
  @moduledoc """
  The two outcomes of the `agents-query` delivery race, pinned deterministically
  (issue #36).

  `agents-query` never returns the peer's answer: it delivers the message and
  its tool result is the *delivery confirmation*, while the answer arrives later
  as a message. Which of the two the coordinator sees is a race, because the
  peer's turn runs while the coordinator's tool batch is executing:

    * the answer lands *after* the batch has produced its result → the tool
      result is the inline confirmation (`"Query delivered to …, which now owes
      you a reply"`);
    * the answer lands *while* the batch is still executing → the batch is
      backgrounded (issue #36's delivery) and the tool result is the machine's
      synthetic "moved to the background" notice instead, with the delivery's
      real result arriving later as a message.

  Both are correct product behaviour. The single test this file replaces
  asserted only the first, so it failed whenever the second happened — filed as
  a flake, but the flake was the test's, not the product's.

  Each test below gates the peer's answer with a real handshake instead of a
  fence: `AgentTurnTestHelpers.park_agent_sends/2` holds the peer's `agents-send`
  in its tool worker until the test releases it, and
  `AgentTurnTestHelpers.park_agent_queries/2` holds the coordinator's batch open
  after its query is delivered. The backgrounded test also parks the peer's
  worker *after* that delivery, so the delivery call's own reply — not a poll —
  is what observes the backgrounding. Which outcome the batch produces is
  therefore decided by the test, not by the scheduler — and the answer still
  arrives exactly once in both.

  Every wait here is on a real agent's progress — a parked tool worker, a
  delivered query, a settled turn — so they use
  `SubAgentToolsHelpers.turn_fence_ms/0` (2000 ms) rather than the project's
  500 ms fence: see that attribute for the measured rationale. The *outcome* is
  pinned by the handshake, never by the timeout, and the hold that keeps the
  batch in flight outlives the fence so a slow host fails a fence (a stuck
  turn) rather than silently flipping the outcome.

  Every assertion of the original test is kept in both: the tool result, the
  peer framing of the query, the answer arriving as a message, unique message
  indices, no outstanding reply debt, and no give-up notice.
  """

  use Nest.DataCase, async: true

  import Mimic
  import Nest.Agents.AgentTestHelpers
  import Nest.Agents.AgentTurnTestHelpers
  import Nest.Agents.SubAgentToolsHelpers

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Machine
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part

  setup :verify_on_exit!

  setup do
    {:ok, vid: upsert_tools_vocation()}
  end

  test "an answer arriving after the batch leaves the inline confirmation", %{vid: vid} do
    {coordinator_pid, coordinator_name, specialist_pid, specialist_name} = start_pair(vid)

    # The peer's answer is parked inside `Nest.Agents.send_message/4` before it
    # reaches the coordinator, so it cannot land while the batch below is
    # executing. That gate is the whole difference between the two outcomes, and
    # the test owns it.
    park_agent_sends(specialist_pid)

    script_coordinator(specialist_name)

    :ok = Agent.chat(coordinator_pid, "ask the specialist")

    # The peer's turn reached the `agents-send` that answers the query and is
    # held there: the query has been delivered, and the answer is still unsent.
    assert_receive {:send_blocked, sender}, turn_fence_ms()

    # The tool result is the delivery confirmation, never the answer: there is no
    # wait to return one from.
    assert Eventually.eventually(
             fn -> query_results(coordinator_pid) != [] end,
             timeout: turn_fence_ms()
           )

    assert [%Part.ToolResult{name: "agents-query", content: content, is_error: false}] =
             query_results(coordinator_pid)

    assert content =~ "Query delivered to #{specialist_name}"
    assert content =~ "owes you a reply"
    refute content =~ "moved to the background"

    # The specialist was asked with the peer framing (the query is a peer's
    # message, decision 7)...
    assert Eventually.eventually(
             fn ->
               Enum.any?(
                 agent_texts(specialist_pid),
                 &(&1 =~ "[Message from agent \"#{coordinator_name}\"]" and &1 =~ "what is 2+2?")
               )
             end,
             timeout: turn_fence_ms()
           )

    # ...and its answer, released only now, arrives as a message in the
    # coordinator's inbox. Decisive park's release: only the batch's own result
    # is waited on between the park's message and this line (one fence), so the
    # 3 s valve cannot fire first — see the invariant on
    # `AgentTurnTestHelpers.park/3`.
    send(sender, :release_send)

    assert Eventually.eventually(
             fn -> Enum.any?(agent_texts(coordinator_pid), &(&1 =~ "the specialist answer")) end,
             timeout: turn_fence_ms()
           )

    # Both turns are over, and the reply discharged the obligation the query
    # created (a give-up notice would be in the coordinator's inbox instead).
    await_idle([coordinator_pid, specialist_pid])

    state = :sys.get_state(coordinator_pid, 500)
    assert_unique_message_indices(state)
    assert Machine.owed_senders(state.live.machine) == []
    refute Enum.any?(agent_texts(coordinator_pid), &(&1 =~ "did not reply"))

    # Delivered exactly once: one entry, no duplicate and no loss.
    assert Enum.count(agent_texts(coordinator_pid), &(&1 =~ "the specialist answer")) == 1
  end

  test "an answer arriving inside the batch backgrounds it", %{vid: vid} do
    {coordinator_pid, coordinator_name, specialist_pid, specialist_name} = start_pair(vid)

    # The peer's answer is parked before it reaches the coordinator, and its
    # worker parks again *after* the delivery...
    park_agent_sends(specialist_pid, hold_result: true)

    # ...while the coordinator's batch is held open *after* its query is
    # delivered, so the answer is guaranteed to land while the batch is still
    # executing: `hold_result` is exactly that hold, and without it the batch
    # would settle first (which is the other test's shape).
    park_agent_queries(coordinator_pid, hold_result: true)

    script_coordinator(specialist_name)

    :ok = Agent.chat(coordinator_pid, "ask the specialist")

    # The batch reached the tool worker, parked before its query.
    assert_receive {:query_blocked, batch}, turn_fence_ms()

    assert Machine.status_for(:sys.get_state(coordinator_pid, 500).live.machine) ==
             :executing_tools

    # Release it: the query is delivered (the peer's turn starts) and the worker
    # parks again *after* the delivery, so the batch is still running for
    # everything asserted below.
    send(batch, :release_query)
    assert_receive {:query_delivered, ^batch}, turn_fence_ms()

    # The peer's turn reached the `agents-send` that answers the query, and is
    # held there too: both sides are parked with the batch in flight.
    assert_receive {:send_blocked, sender}, turn_fence_ms()

    assert Machine.status_for(:sys.get_state(coordinator_pid, 500).live.machine) ==
             :executing_tools

    # Release the answer: it lands while the batch is executing, so the batch is
    # moved to the background and the answer is delivered now.
    send(sender, :release_send)

    # The delivery call returns only once the coordinator has handled it — the
    # backgrounding — so this handshake, not a poll, is what observes the
    # outcome (a poll here would put a whole-state `:sys.get_state` in the same
    # mailbox as the delivery, every 10 ms). The worker parks again after the
    # delivery, so the batch is still running; release it at once.
    assert_receive {:send_delivered, ^sender}, turn_fence_ms()
    send(sender, :release_result)

    assert Eventually.eventually(
             fn -> query_results(coordinator_pid) != [] end,
             timeout: turn_fence_ms()
           )

    # The tool result is the machine's synthetic notice, not the confirmation
    # the delivery produced: the delivery's real result arrives later, as a
    # message (asserted below).
    assert [%Part.ToolResult{name: "agents-query", content: content, is_error: false}] =
             query_results(coordinator_pid)

    assert content =~ "moved to the background"
    assert content =~ "arrive later as a message"
    refute content =~ "owes you a reply"

    # The answer arrives as a message in the coordinator's inbox...
    assert Eventually.eventually(
             fn -> Enum.any?(agent_texts(coordinator_pid), &(&1 =~ "the specialist answer")) end,
             timeout: turn_fence_ms()
           )

    # ...and the peer was asked with the peer framing (the query is a peer's
    # message, decision 7).
    assert Eventually.eventually(
             fn ->
               Enum.any?(
                 agent_texts(specialist_pid),
                 &(&1 =~ "[Message from agent \"#{coordinator_name}\"]" and &1 =~ "what is 2+2?")
               )
             end,
             timeout: turn_fence_ms()
           )

    # The batch returns with no live worker to settle it, so its *real* result
    # arrives as a notice — which is where the confirmation the delivery
    # produced shows up. Decisive park's release: between the hold and this line
    # only the peer's turn is waited on (one fence); everything after the
    # delivery handshake is already true, so the 3 s valve cannot fire first —
    # see the invariant on `AgentTurnTestHelpers.park/3`.
    send(batch, :release_result)

    assert Eventually.eventually(
             fn ->
               Enum.any?(
                 agent_texts(coordinator_pid),
                 &(&1 =~ "Query delivered to #{specialist_name}" and &1 =~ "owes you a reply")
               )
             end,
             timeout: turn_fence_ms()
           )

    # Both turns are over, and the reply discharged the obligation the query
    # created (a give-up notice would be in the coordinator's inbox instead).
    await_idle([coordinator_pid, specialist_pid])

    state = :sys.get_state(coordinator_pid, 500)
    assert_unique_message_indices(state)
    assert Machine.owed_senders(state.live.machine) == []
    refute Enum.any?(agent_texts(coordinator_pid), &(&1 =~ "did not reply"))

    # Delivered exactly once: the backgrounding did not duplicate the answer and
    # the batch's late result did not lose it.
    assert Enum.count(agent_texts(coordinator_pid), &(&1 =~ "the specialist answer")) == 1
  end

  # The coordinator's script: it queries the specialist, then answers the request
  # that carries whatever arrives. Both tests use the same three responses, in
  # the same order.
  defp script_coordinator(specialist_name) do
    MockClient.set_tool_response(%{
      text: "querying",
      tool_calls: [
        %{
          id: "call_query_1",
          name: "agents-query",
          arguments: %{"name" => specialist_name, "prompt" => "what is 2+2?"}
        }
      ]
    })

    MockClient.set_response("coordinator done")
    MockClient.set_response("coordinator read the answer")
  end

  # A coordinator plus a specialist that answers a query the way an agent is
  # asked to: with `agents-send` back to the requester, which is what discharges
  # the reply it owes. Nothing waits for that, so its turn runs alongside the
  # coordinator's.
  defp start_pair(vid) do
    {coordinator_pid, coordinator_name} =
      start_agent(%{
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vid
      })

    space_id = current_space_id()
    specialist_name = "specialist-#{System.unique_integer([:positive])}"

    specialist_pid =
      start_mocked_specialist(space_id, specialist_name, [
        {:tool,
         %{
           text: "replying",
           tool_calls: [
             %{
               id: "reply_1",
               name: "agents-send",
               arguments: %{"name" => coordinator_name, "message" => "the specialist answer"}
             }
           ]
         }},
        {:text, "specialist done"}
      ])

    {coordinator_pid, coordinator_name, specialist_pid, specialist_name}
  end
end
