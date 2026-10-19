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

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Agents.Agent.Turn.Dispatch
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.ToolCall
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Reserve

  import Mimic

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
    assert {:ok, :queued} = Agent.deliver_note(pid, "peer", "peer note")
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
             "[From agent peer | mode: act]\npeer note"

    # The delivered message rides the turn the batch yielded, so the model sees
    # it in this request.
    assert Enum.any?(
             user_texts(delivered_request),
             &(&1 =~ "[From agent peer | mode: act]\npeer note")
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

    assert late =~ "[From agent #{name} | mode: act]\nnote"
    assert late =~ "Message queued for #{name} (busy)"

    AgentTestHelpers.assert_unique_message_indices(state.chat_state.messages)
  end

  test "a batch-start delivery the context cannot hold stays queued and leaves the mode alone" do
    # The other half of the deferral armed at the batch's start: it runs the same
    # `Backgrounding.step/3` the arrival path runs, so a delivery the context
    # cannot hold is *declined* — and a decline must leave nothing behind. The
    # mode in particular: `Executor.peek_inbox/1` applies the queued batch's mode
    # (the message the machine appends is built from `ctx.mode`, and the mode
    # frame a subscriber sees while a batch is still executing is read from
    # `state.live.mode`), so a drain that delivers nothing has to put it back —
    # otherwise `Turn.prepare/1` rebuilds `ctx.mode`/`ctx.caps` for the ongoing
    # turn from a message that was never delivered (issue #103).
    {pid, name} =
      start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: multi_mode_vocation_id_for_test()
      })

    park_llm_requests(pid)
    park_agent_sends(pid)

    MockClient.set_tool_response(%{
      text: "Sending",
      tool_calls: [
        %{id: "send_1", name: "agents-send", arguments: %{"name" => name, "message" => "note"}}
      ]
    })

    # A limit between the two decisions, derived from the fixture's own numbers
    # rather than hard-coded. The batch's preflight projects
    # `size(messages) + projected(call)` — a tool call's projection is tiny —
    # while the delivery projects `size(messages ++ [user])`, i.e. it carries the
    # queued message itself. So a limit one third of that message above
    # `size + reserve` starts the batch and declines the delivery, by a margin
    # that does not depend on the estimator's exact chars-per-token. The `+ 100`
    # is the assistant row the response appends, which the delivery's projection
    # also carries. The message is kept well under the async-message cap so the
    # delivery carries its text rather than a scratch-file pointer (a pointer
    # would be small enough to fit and would make this test vacuous).
    queued = Enum.map_join(1..1_700, " ", &"note #{&1}")

    :ok = Agent.chat(pid, "start the turn")
    {_first, llm1} = next_request()

    delivered = Dispatch.build_user_message(queued, "plan")

    limit =
      ConversationSize.size(Agent.get_messages(pid, 1_000)) + 100 + 8_192 +
        div(ConversationSize.size([delivered]), 3)

    # Under 40_960, so the reserve the two decisions use is its 8_192 floor.
    assert Reserve.compaction_reserve(limit) == 8_192
    assert limit < 40_960

    set_context_limit(pid, limit, silence_reminders: true)

    # The human's message — in a mode the agent is not in — arrives while the
    # model is still streaming, so it queues: the streaming arm must queue it.
    :ok = Agent.chat(pid, queued, "plan", "alice", true)
    assert_receive {:chat_inbox, %{count: 1}}, 500

    # The response asks for the tool batch, whose worker parks inside its call:
    # the batch starts, and the deferral armed there runs the drain — which this
    # context declines.
    release_llm(llm1)
    assert_receive {:send_blocked, tool}, 500

    # allowlist: snapshot — status + work + mode + inbox + messages
    state = :sys.get_state(pid, 1_000)

    # The fixture's own decisions, asserted so the test cannot pass on a limit
    # that happens to fit. The second is the one the decline reads:
    # `Backgrounding.fits?/2` runs this same `Dispatch.preflight_decision/2`.
    assert :needs_compaction =
             Dispatch.preflight_decision(state.chat_state.messages ++ [delivered], limit)

    assert {:fits, _} =
             BatchSizer.preflight(
               [%ToolCall{id: "send_1", name: "agents-send", arguments: %{}}],
               Turn.build_ctx(state)
             )

    # Nothing was delivered: the entry is still queued, the batch was not moved
    # to the background, and the transcript gained no message at all (the
    # assistant row the response appended is its last).
    assert Machine.status_for(state.live.machine) == :executing_tools
    assert [%{content: ^queued, kind: :user, mode: "plan"}] = state.live.inbox
    assert state.live.machine.work.backgrounded == %{}
    assert state.live.machine.work.active_worker == tool
    assert Enum.map(state.chat_state.messages, &elem(&1, 0)) == [:system, :user, :assistant]

    # ... and the mode did not stick. The peek published the queued message's
    # mode while the batch was still executing — that frame's timing is pinned
    # by `TurnBackgroundingTest` 1.1.10, because `currentMode` is read from
    # `state.live.mode` — and the undelivered attempt published the agent's own
    # mode again, so the UI is not left showing a mode that never took effect.
    assert state.live.mode == "act"
    assert_receive {:chat_status, %{currentMode: "plan"}}, 500
    assert_receive {:chat_status, %{currentMode: "act"}}, 500

    # Leave the agent idle for the teardown, with the entry dropped: the decline,
    # not the fabricated limit, is what this test pins.
    :sys.replace_state(
      pid,
      fn state -> %{state | live: %{state.live | inbox: [], machine: Machine.new()}} end,
      1_000
    )

    Process.exit(tool, :kill)
  end

  # The context limit the fixture's two decisions are taken against. Set after
  # the turn opens, so the request that asks for the batch is sized against it
  # too — which is what makes the batch start and the delivery decline.
  #
  # `silence_reminders: true` marks every context threshold already announced.
  # Lowering the limit mid-turn legitimately puts the agent over the first one,
  # and the reminder it appends is a `user`/`assistant` pair of its own — which
  # would change the transcript this fixture asserts on for a reason that has
  # nothing to do with the fit decision. The thresholds come from
  # `ContextReminder.threshold_atoms/0`, so adding one there does not silently
  # re-introduce the pair here.
  defp set_context_limit(pid, limit, opts) do
    announced =
      if Keyword.get(opts, :silence_reminders, false),
        do: MapSet.new(ContextReminder.threshold_atoms()),
        else: nil

    :sys.replace_state(
      pid,
      fn state ->
        state = %{state | llm_metrics: %{state.llm_metrics | context_limit: limit}}

        if announced,
          do: %{state | live: %{state.live | crossed_thresholds: announced}},
          else: state
      end,
      1_000
    )
  end
end
