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
  delivered query, a settled turn — and each one is the *arrival* of the frame
  that proves it, never a poll of the clock: the parked handshakes above, each
  agent's own `{:chat_message, …}` / `{:chat_status, …}` broadcast for anything
  read out of a transcript or waited on (the coordinator is subscribed by
  `start_agent/1`, the specialist by `start_mocked_specialist/3`), and this
  file's own `assert_settled/1` — the idle frame that carries an empty queue —
  for a turn whose end drains what arrived during it. The *outcome* is
  pinned by the handshake, never by the timeout, and the hold that keeps the
  batch in flight outlives the fence so a slow host fails a fence (a stuck
  turn) rather than silently flipping the outcome.

  Both tests assert the claims that differ between the outcomes: the tool
  result (the delivery's confirmation inline, the machine's synthetic notice
  when backgrounded), the answer arriving exactly once, unique message indices,
  and no give-up notice. The peer framing of the delivered query is the
  delivery's own behaviour, identical in both outcomes, so the first test
  asserts it and the second only consumes that frame as a fence.
  """

  use Nest.DataCase, async: true

  import Mimic
  import Nest.Agents.AgentTestHelpers
  import Nest.Agents.AgentTurnTestHelpers
  import Nest.Agents.SubAgentToolsHelpers

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part

  setup :verify_on_exit!

  setup do
    {:ok, vid: upsert_tools_vocation()}
  end

  test "an answer arriving after the batch leaves the inline confirmation", %{vid: vid} do
    {coordinator_pid, coordinator_name, specialist_pid, specialist_name} = start_pair(vid)

    # The peer's answer is parked inside `Nest.Agents.send_note/6` before it
    # reaches the coordinator, so it cannot land while the batch below is
    # executing. That gate is the whole difference between the two outcomes, and
    # the test owns it.
    park_agent_sends(specialist_pid)

    script_coordinator(specialist_name)

    :ok = Agent.chat(coordinator_pid, "ask the specialist", nil, nil, true)

    # The peer's turn reached the `agents-send` that answers the query and is
    # held there: the query has been delivered, and the answer is still unsent.
    assert_receive {:send_blocked, sender}, 1_000

    # The tool result is the delivery confirmation, never the answer: there is no
    # wait to return one from, so the coordinator's own `{:tool, …}` broadcast —
    # emitted in the settle that appended it — is the whole fence.
    assert_receive {:chat_message, {:tool, %{parts: [%Part.ToolResult{name: "agents-query"}]}}},
                   1_000

    assert [%Part.ToolResult{name: "agents-query", content: content, is_error: false}] =
             query_results(coordinator_pid)

    assert content =~ "Query delivered to #{specialist_name}"
    assert content =~ "owes you a reply"
    refute content =~ "moved to the background"

    # The specialist was asked with the peer framing (the query is a peer's
    # message, decision 7). No wait needed: `{:send_blocked, …}` above is the
    # fence — the query was appended inside the delivery call, which returned
    # before the peer's own `agents-send` worker reached that park. The frame is
    # the specialist's own `{:chat_message, {:user, …}}` broadcast, which this
    # test pid is subscribed to (`start_mocked_specialist/3`); consuming it here
    # is also what keeps the answer's frame below unambiguous, since the two
    # deliveries differ only in their sender and a `chat:message` frame carries
    # no agent identity.
    assert_receive {:chat_message, {:user, %{parts: [%Part.Text{text: "[From agent " <> rest}]}}},
                   1_000

    assert rest == "#{coordinator_name}, agents-send reply required | mode: act]\nwhat is 2+2?"

    # ...and its answer, released only now, arrives as a message in the
    # coordinator's inbox — the delivery appends it inside the call, so the
    # coordinator's own `{:user, …}` broadcast is the fence. Decisive park's
    # release: only the batch's own result is waited on between the park's
    # message and this line (one fence), so the 3 s valve cannot fire first —
    # see the invariant on `AgentTurnTestHelpers.park/3`.
    send(sender, :release_send)

    assert_receive {:chat_message, {:user, %{parts: [%Part.Text{text: "[From agent " <> _}]}}},
                   1_000

    # Both turns are over, and the reply discharged the obligation the query
    # created (a give-up notice would be in the coordinator's inbox instead).
    #
    # The fence is the idle frame that carries an *empty* queue, not the first
    # idle frame. The answer was delivered while the coordinator's turn was
    # still running, so that turn's end drains it: a turn ends with
    # `[{:finalize, :clean}, {:drain_inbox}]`, in that order, so the transient
    # idle that ends the turn reports the queue it is about to drain
    # (`pendingMessageCount` is `length(live.inbox)` at broadcast time) and the
    # drain's own turn starts after it. A bare idle fence matches *that* frame
    # and returns with the drain's turn still in flight, which is the
    # `:streaming` the teardown's zero-remaining check catches — the precommit
    # flake this replaces. An empty queue is the state no further drain can
    # start from, so the fence below is the last turn's.
    assert_settled(coordinator_name)
    assert_settled(specialist_name)

    # allowlist: snapshot — messages
    state = :sys.get_state(coordinator_pid, 1_000)
    assert_unique_message_indices(state.chat_state.messages)
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

    :ok = Agent.chat(coordinator_pid, "ask the specialist", nil, nil, true)

    # The batch reached the tool worker, parked before its query.
    assert_receive {:query_blocked, batch}, 1_000

    assert Agent.get_public_info(coordinator_pid, 1_000).status == :executing_tools

    # Release it: the query is delivered (the peer's turn starts) and the worker
    # parks again *after* the delivery, so the batch is still running for
    # everything asserted below.
    send(batch, :release_query)
    assert_receive {:query_delivered, ^batch}, 1_000

    # The peer's turn reached the `agents-send` that answers the query, and is
    # held there too: both sides are parked with the batch in flight.
    assert_receive {:send_blocked, sender}, 1_000

    # The query the specialist is answering, on its own `{:chat_message, {:user,
    # …}}` broadcast (this test pid is subscribed to both agents' topics).
    # Consuming it here keeps the answer's frame below unambiguous: the two
    # deliveries differ only in their sender, and a `chat:message` frame carries
    # no agent identity. Its text — the peer framing of a delivered query — is
    # the delivery's own behaviour, identical in both outcomes, and the test
    # above asserts it; here the frame is only a fence.
    assert_receive {:chat_message, {:user, %{parts: [%Part.Text{text: "[From agent " <> _}]}}},
                   1_000

    # Release the answer: it lands while the batch is executing, so the batch is
    # moved to the background and the answer is delivered now.
    send(sender, :release_send)

    # The delivery call returns only once the coordinator has handled it — the
    # backgrounding — so this handshake, not a poll, is what observes the
    # outcome (a poll here would put a whole-state `:sys.get_state` in the same
    # mailbox as the delivery, every 10 ms). The worker parks again after the
    # delivery, so the batch is still running; release it at once.
    assert_receive {:send_delivered, ^sender}, 1_000
    send(sender, :release_result)

    # The backgrounding answered the batch with a synthetic `{:tool, …}` in the
    # settle that appended it, so that broadcast is the fence.
    assert_receive {:chat_message, {:tool, %{parts: [%Part.ToolResult{name: "agents-query"}]}}},
                   1_000

    # The tool result is the machine's synthetic notice, not the confirmation
    # the delivery produced: the delivery's real result arrives later, as a
    # message (asserted below).
    assert [%Part.ToolResult{name: "agents-query", content: content, is_error: false}] =
             query_results(coordinator_pid)

    assert content =~ "moved to the background"
    assert content =~ "arrive later as a message"
    refute content =~ "owes you a reply"

    # The answer arrives as a message in the coordinator's inbox — appended
    # inside the delivery call, so the coordinator's own `{:user, …}` broadcast
    # is the fence...
    assert_receive {:chat_message, {:user, %{parts: [%Part.Text{text: "[From agent " <> _}]}}},
                   1_000

    # The batch returns with no live worker to settle it, so its *real* result
    # arrives as a notice — which is where the confirmation the delivery
    # produced shows up. A notice renders behind the runtime's header (never an
    # agent's), so the coordinator's own broadcast of it is the fence. Decisive
    # park's release: between the hold and this line only the batch's own result
    # and the peer's turn are waited on (two fences); everything after the
    # delivery handshake is already true, so the 3 s valve cannot fire first —
    # see the invariant on `AgentTurnTestHelpers.park/3`.
    send(batch, :release_result)

    # The delivered row states the recipient's mode in the header that heads its
    # body, so the wire text is that header and then the notice; the client
    # strips the header at render time (`assets/js/utils/stripHeader.js`), so it
    # never reaches the operator.
    #
    # The notice is two parts since issue #139: the prose that announces the
    # command, then the command's own output, which the wire marks with
    # `commandOutputParts` so the browser renders it as output rather than as
    # markdown. The confirmation this test is about is in the output.
    assert_receive {:chat_message,
                    {:user,
                     %{
                       parts: [
                         %Part.Text{
                           text: "[From nest runtime | mode: act]\nYour backgrounded command" <> _
                         },
                         %Part.Text{text: output}
                       ],
                       metadata: %{"command_output_parts" => [1]}
                     }}},
                   1_000

    assert output =~ "Query delivered to #{specialist_name}"

    # The release starts *two* coordinator turns — the backgrounded batch's own
    # turn, then the batch's late-result notice — and both `idle` frames are
    # queued by the time the wait runs, so a single fence would match the first
    # one and return with the second turn still in flight (measured: `:streaming`
    # at this point). `statuses_until_idle/2` consumes the first turn and asserts
    # the sequence it ended with, so the fence below is the notice's own turn.
    assert statuses_until_idle(coordinator_name) == [
             "streaming",
             "executing_tools",
             "streaming",
             "idle"
           ]

    # Both coordinator turns are over, the specialist's turn is too, and the reply
    # discharged the obligation the query created (a give-up notice would be in the
    # coordinator's inbox instead).
    # The same settled fence as the test above: a turn end that drains publishes
    # an idle frame before the drain's own turn runs, so the fence is the
    # empty-queue idle rather than the first queued one.
    assert_settled(coordinator_name)
    assert_settled(specialist_name)

    # allowlist: snapshot — messages
    state = :sys.get_state(coordinator_pid, 1_000)
    assert_unique_message_indices(state.chat_state.messages)
    refute Enum.any?(agent_texts(coordinator_pid), &(&1 =~ "did not reply"))

    # Delivered exactly once: the backgrounding did not duplicate the answer and
    # the batch's late result did not lose it.
    assert Enum.count(agent_texts(coordinator_pid), &(&1 =~ "the specialist answer")) == 1
  end

  # The idle fence for a wait that can span a turn end that drains: the agent's
  # idle frame carrying an *empty* queue, which is the state no further drain can
  # start from. `SubAgentToolsHelpers.await_idle/1`'s bare frame is the *first*
  # queued idle — `Nest.Agents.Agent.IdleFenceTest` pins that contract, and it is
  # right for a wait that spans a single turn. This is the fence for a wait that
  # spans the drained turn, where that first frame is the transient one.
  defp assert_settled(name) do
    assert_receive {:chat_status, %{name: ^name, status: "idle", pendingMessageCount: 0}}, 1_000
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
