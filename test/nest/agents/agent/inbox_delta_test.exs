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
    # the topic (name/space) and the queue. Subscribed here for the fold-back
    # test below; the resync test reads its own agent's topic, which
    # `AgentTestHelpers.start_agent/1` subscribes this process to.
    Phoenix.PubSub.subscribe(Nest.PubSub, "agent:1:delta")
    %{state: %Agent{name: "delta", space_id: 1}}
  end

  # Enqueue one runtime entry and return the state and its frame.
  defp enqueue(state, content) do
    state = Inbox.enqueue_internal(state, "peer", content, :agent)
    # The suite's fence for `test/` (`test/test_helper.exs:157`); the frame is
    # broadcast in this process, so the wait is already over.
    assert_receive {:chat_inbox, frame}, 1_000
    {state, frame}
  end

  # Apply one frame to a client-side list, exactly as the JS store does:
  # `append` concatenates, `remove` filters the named ids out.
  defp apply_frame(list, %{op: "append", messages: messages}), do: list ++ messages

  defp apply_frame(list, %{op: "remove", ids: ids}),
    do: Enum.reject(list, &(&1["id"] in ids))

  test "every mutation is one frame, and the frames fold back into the queue", %{state: state} do
    # The whole protocol in one pass: an enqueue (append) and a consume
    # (remove). The client applies each frame to its own list, and the result
    # must be the server's queue — which is what makes the sequence number
    # meaningful and the resync frame a repair rather than a guess. It is also
    # what fails if a frame ever carries the whole queue instead of its own
    # mutation (issue #27): the client would fold in duplicates.
    client = []

    {state, frame1} = enqueue(state, "one")
    client = apply_frame(client, frame1)

    {state, frame2} = enqueue(state, "two")
    client = apply_frame(client, frame2)

    assert frame1.inboxSeq == 1
    assert frame2.inboxSeq == 2
    assert frame2.count == 2

    # A drain consumes the peeked batch: the frame names every id that went.
    before = state.live.inbox
    batch = Inbox.batch(before)
    state = Inbox.consume_and_broadcast(state, batch)
    # The suite's fence for `test/` (`test/test_helper.exs:157`); the frame is
    # broadcast in this process, so the wait is already over.
    assert_receive {:chat_inbox, frame3}, 1_000
    client = apply_frame(client, frame3)

    assert frame3.op == "remove"
    assert frame3.inboxSeq == 3
    assert frame3.count == 0
    assert Enum.sort(frame3.ids) == Enum.sort(Enum.map(before, & &1.id))

    assert client == Inbox.serialize(state.live.inbox)
  end

  test "a resync snapshot carries the list and the sequence the last frame named" do
    {pid, _name} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
    TimelineTestHelpers.set_status(pid, :streaming)

    assert {:ok, :queued} = Agent.deliver_note(pid, "peer", "queued")
    assert_receive {:chat_inbox, %{op: "append", count: 1, inboxSeq: seq}}, 1_000

    info = Agent.get_public_info(pid, 1_000)

    # One snapshot, one call: the channel's `chat:inbox` reply (the resync
    # frame) is built from exactly this pair, so a client that replaces its list
    # from it resumes the delta stream at `seq` with no gap — and a client whose
    # own sequence is behind that has a repair, not a hole.
    assert info.inbox_seq == seq
    assert [%{"content" => "queued"}] = info.pending_messages

    TimelineTestHelpers.set_status(pid, :idle)
  end
end
