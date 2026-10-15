defmodule Nest.Agents.Agent.InboxDeltaTest do
  @moduledoc """
  The `chat:inbox` delta protocol (issue #27).

  One frame per queue mutation, carrying the mutation, the authoritative queue
  length after it, and the frame's position in the agent's stream (`inboxSeq`);
  and the resync frame — the full list with the sequence it was taken at — that
  a client which missed a frame converges on. The protocol's point is that no
  frame carries the whole queue on a per-enqueue path, and its safety property
  is that a client applying every frame in order holds exactly the server's
  queue.
  """

  use Nest.DataCase, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.AgentTestHelpers
  alias Nest.TimelineTestHelpers

  setup do
    # A bare state is enough for the frame shapes: the delta functions read only
    # the topic (name/space) and the queue. Subscribed here so every test below
    # reads the frames in the order they were emitted.
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:1:delta")
    %{state: %Agent{name: "delta", space_id: 1}}
  end

  # Enqueue one runtime entry and return the state, the entry, and its frame.
  defp enqueue(state, content) do
    state = Inbox.enqueue_internal(state, "peer", content, :agent)
    assert_receive {:chat_inbox, frame}
    {state, List.last(state.live.inbox), frame}
  end

  # Apply one frame to a client-side list, exactly as the JS store does:
  # `append` concatenates, `update` replaces by id in place, `remove` filters
  # the named ids out.
  defp apply_frame(list, %{op: "append", messages: messages}), do: list ++ messages

  defp apply_frame(list, %{op: "update", messages: messages}) do
    Enum.map(list, fn held ->
      Enum.find(messages, held, &(&1["id"] == held["id"]))
    end)
  end

  defp apply_frame(list, %{op: "remove", ids: ids}),
    do: Enum.reject(list, &(&1["id"] in ids))

  test "an append frame carries the new entry and the length, never the queue", %{state: state} do
    # The frame is the delta for its own enqueue, so its size does not grow with
    # the queue — the quadratic term #27 removes. `messages` holds the one entry
    # this enqueue added; `count` says how many the queue now holds.
    state =
      Enum.reduce(1..3, state, fn n, state ->
        {state, entry, frame} = enqueue(state, "msg #{n}")

        assert frame.op == "append"
        assert frame.count == n
        assert frame.inboxSeq == n
        assert frame.messages == Inbox.serialize([entry])
        assert length(state.live.inbox) == n
        state
      end)

    assert length(state.live.inbox) == 3
  end

  test "every mutation is one frame, and the frames fold back into the queue", %{state: state} do
    # The whole protocol in one pass: an enqueue (append), an
    # `agents-last-message` fetch (update, in place), a consume (remove) and a
    # prune (remove). The client applies each frame to its own list, and the
    # result must be the server's queue — which is what makes the sequence
    # number meaningful and the resync frame a repair rather than a guess.
    client = []

    {state, _first, frame1} = enqueue(state, "one")
    client = apply_frame(client, frame1)

    {state, second, frame2} = enqueue(state, "two")
    client = apply_frame(client, frame2)

    assert frame1.inboxSeq == 1
    assert frame2.inboxSeq == 2
    assert frame2.count == 2

    # The fetch marks the entry retrieved in place: the frame is an update for
    # that entry — the copy the queue now holds — and the length is unchanged.
    {state, marked} = Inbox.mark_retrieved(state, "peer")
    assert marked.id == second.id
    assert marked.retrieved == true
    assert_receive {:chat_inbox, frame3}
    client = apply_frame(client, frame3)

    assert frame3.op == "update"
    assert frame3.inboxSeq == 3
    assert frame3.count == 2
    assert [%{"retrieved" => true, "id" => id}] = frame3.messages
    assert id == marked.id

    # A drain consumes the peeked batch: the frame names every id that went —
    # the delivered batch *and* the retrieved entry the consume drops with it.
    before = state.live.inbox
    batch = Inbox.batch(before)
    state = Inbox.consume_and_broadcast(state, batch)
    assert_receive {:chat_inbox, frame4}
    client = apply_frame(client, frame4)

    assert frame4.op == "remove"
    assert frame4.inboxSeq == 4
    assert frame4.count == 0
    assert Enum.sort(frame4.ids) == Enum.sort(Enum.map(before, & &1.id))

    assert state.live.inbox == []
    assert client == Inbox.serialize(state.live.inbox)
  end

  test "a prune broadcasts the ids it dropped, not the queue it left", %{state: state} do
    {state, _first, _frame} = enqueue(state, "one")
    {state, second, _frame} = enqueue(state, "two")

    # `agents-last-message` takes the newest entry from that sender, marking it
    # retrieved in place; a drain that finds only retrieved entries left prunes
    # them instead of delivering.
    {state, marked} = Inbox.mark_retrieved(state, "peer")
    assert marked.id == second.id
    assert marked.retrieved == true
    assert_receive {:chat_inbox, %{op: "update"}}

    state = Inbox.prune_retrieved(state)

    assert_receive {:chat_inbox, %{op: "remove", count: 1, ids: [id]}}
    assert id == marked.id
    assert Enum.map(state.live.inbox, & &1.content) == ["one"]
  end

  test "a resync snapshot carries the list and the sequence the last frame named" do
    {pid, _name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
    TimelineTestHelpers.set_status(pid, :streaming)

    assert {:ok, :queued} = Agent.deliver_message(pid, "peer", "queued")
    assert_receive {:chat_inbox, %{op: "append", count: 1, inboxSeq: seq}}, 1_000

    info = Agent.get_public_info(pid, 1_000)

    # One snapshot, one call: the channel's `chat:inbox` reply (the resync
    # frame) is built from exactly this pair, so a client that replaces its list
    # from it resumes the delta stream at `seq` with no gap — and a client whose
    # own sequence is behind that has a repair, not a hole.
    assert info.inbox_seq == seq
    assert [%{"content" => "queued"}] = info.pending_messages
    assert info.pending_message_count == 1

    TimelineTestHelpers.set_status(pid, :idle)
  end
end
