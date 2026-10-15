defmodule Nest.Agents.Agent.TurnBatchStartDeliveryTest do
  @moduledoc """
  The deferral armed from the batch's own side — the regression test for #103.

  A message that arrives while the model is still streaming the response that
  asks for a tool batch is queued: the streaming arm has to queue it (there is
  no batch to move yet, and an in-flight request is never interrupted). The
  batch that response asks for is interruptible from the moment its worker
  registers, so the queued message is delivered *there* — the batch moves to the
  background and the message lands in the transcript.

  Without that second moment the deferral was only ever attempted by the arrival
  path, which asks "can this batch be backgrounded?" once, when a message
  arrives. A message that had already arrived before the batch existed was
  therefore delivered only when the *next* arrival happened to land while the
  batch executed — one delivery late, self-correcting on the following arrival.
  That is the shape #103 reports.

  Split from `TurnBackgroundingTest` — which is at the credo file cap — beside
  the same parked harnesses; the machine-level half of the decision lives in
  `MachineBackgroundingTest`.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent.Machine

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers
  import Nest.Agents.AgentTurnTestHelpers

  test "a message queued before the batch starts is delivered when the batch starts" do
    {pid, name} =
      start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: programmer_vocation_id_for_test()
      })

    park_llm_requests(pid)
    park_agent_sends(pid, hold_result: true)

    MockClient.set_tool_response(%{
      text: "Sending",
      tool_calls: [
        %{id: "send_1", name: "agents-send", arguments: %{"name" => name, "message" => "note"}}
      ]
    })

    MockClient.set_response("After the note")
    MockClient.set_response("After the batch")

    :ok = Agent.chat(pid, "start the turn")

    {_first, llm1} = next_request()

    # The peer's message arrives while the model is still streaming the response
    # that asks for the batch: the batch does not exist yet, so the streaming arm
    # queues the message. That disposition is correct and must not change.
    assert {:ok, :queued} = Agent.deliver_message(pid, "peer", "peer note")
    assert_receive {:chat_inbox, %{count: 1}}, 500

    # The response asks for the tool batch. Its worker parks inside its call, so
    # the agent is `:executing_tools` with a live worker and nothing else in
    # flight: the batch is interruptible, and the queued message is delivered
    # *now* rather than at the next arrival.
    release_llm(llm1)
    assert_receive {:send_blocked, tool}, 500

    {delivered_request, llm2} = next_request()

    # allowlist: snapshot — status + work.backgrounded + inbox + messages
    state = :sys.get_state(pid, 1_000)

    # The batch moved to the background and is still running (its worker is
    # parked inside its call), and the message is in the transcript — the
    # delivery did not wait for the batch to return, and it did not wait for a
    # second arrival.
    assert Machine.status_for(state.live.machine) == :streaming
    assert map_size(state.live.machine.work.backgrounded) == 1
    assert state.live.inbox == []

    assert Enum.map(state.chat_state.messages, &elem(&1, 0)) ==
             [:system, :user, :assistant, :tool, :assistant, :user]

    # The synthetic result answers the batch's call and says the real result
    # arrives later; the ack is the machine's own.
    synthetic = Enum.at(state.chat_state.messages, 3)
    ack = text_of(Enum.at(state.chat_state.messages, 4))

    assert length(tool_texts(synthetic)) == 1
    assert Enum.all?(tool_texts(synthetic), &(&1 =~ "moved to the background"))
    assert ack =~ "running in the background"

    assert text_of(Enum.at(state.chat_state.messages, 5)) ==
             "[mode: chat]\n[Message from agent \"peer\"]\npeer note"

    # The delivered message rides the turn the batch yielded, so the model sees
    # it in this request.
    assert Enum.any?(
             user_texts(delivered_request),
             &(&1 =~ "[Message from agent \"peer\"]\npeer note")
           )

    # Releasing the batch runs its `agents-send` while this agent is streaming,
    # so the peer's entry queues behind the delivered message, and the batch's
    # own result then arrives as a queued notice behind it.
    send(tool, :release_send)
    assert_receive {:send_delivered, ^tool}, 500
    assert_receive {:chat_inbox, %{count: 1}}, 500
    send(tool, :release_result)
    assert_receive {:chat_inbox, %{count: 2}}, 500

    # The delivered message's turn ends, and the boundary drain delivers the two
    # queued entries as one batch.
    release_llm(llm2)
    {_third, llm3} = next_request()
    release_llm(llm3)

    # streaming -> executing_tools (the batch) -> streaming (the deferral armed
    # at the batch's start) -> idle. No `idle` before that third `streaming`: the
    # delivery did not wait for a turn end.
    assert statuses_until_idle(name) == ["streaming", "executing_tools", "streaming", "idle"]

    # The notice's own turn, which ends the run.
    assert statuses_until_idle(name) == ["streaming", "idle"]

    # allowlist: snapshot — status + work.backgrounded + inbox + messages
    state = :sys.get_state(pid, 1_000)

    assert Machine.status_for(state.live.machine) == :idle
    assert state.live.machine.work.backgrounded == %{}
    assert state.live.inbox == []

    # Both later deliveries land in the drain that ends the delivered turn's
    # turn, in one batch: the batch's own send reports the disposition it
    # resolved (queued — the agent was streaming when it landed), and the notice
    # reports the batch's real result.
    late =
      state.chat_state.messages
      |> Enum.find(&(&1 |> text_of() |> String.contains?("backgrounded command")))
      |> text_of()

    assert late =~ "[Message from agent \"#{name}\"]\nnote"
    assert late =~ "Message queued for #{name} (busy)"

    AgentTestHelpers.assert_unique_message_indices(state.chat_state.messages)
  end
end
