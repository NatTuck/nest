defmodule Nest.Agents.Agent.InboxSerializationTest do
  @moduledoc """
  The inbox's wire shape and its pure selection rules: `serialize/1`,
  `batch/1`, `query_senders/1`, `Inbox.Mode.drain_mode/1`, the two
  self-produced enqueues, and the delivery-id/consume API.

  Split out of `InboxTest` (which owns the delivery/disposition contract) when
  that file reached the credo source-file cap; the rendering half is
  `Nest.Agents.Agent.InboxRenderTest`'s. The behavior contract is carried by
  the tests and their inline `#` comments, exactly as there.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox

  describe "entry shape and serialization" do
    test "serialize/1 emits the wire shape the browser renders, for every kind" do
      # intentional: the channel/browser contract is exactly these six keys;
      # `kind` is the entry's provenance (a peer's words, a query that owes a
      # reply, the runtime speaking for itself, or a human's words), `mode`
      # carries the human's requested mode (nil for every other kind), and
      # `human` is true only for a prompt the human typed — the `user` kind is
      # shared with an `agents-spawn` `query` kickoff, so the flag is the only
      # way a reader can tell them apart.
      at = ~U[2026-01-02 03:04:05Z]

      entries = [
        %{
          id: "e1",
          from: "peer",
          content: "from an agent",
          timestamp: at,
          kind: :agent,
          mode: nil,
          human?: false
        },
        %{
          id: "e2",
          from: "alice",
          content: "from a human",
          timestamp: at,
          kind: :user,
          mode: "plan",
          human?: true
        },
        %{
          id: "e3",
          from: nil,
          content: "from nobody",
          timestamp: at,
          kind: :user,
          mode: nil,
          human?: false
        },
        %{
          id: "e4",
          from: "peer",
          content: "a question",
          timestamp: at,
          kind: :query,
          mode: nil,
          human?: false
        },
        %{
          id: "e5",
          from: nil,
          content: "a notice",
          timestamp: at,
          kind: :notice,
          mode: nil,
          human?: false
        }
      ]

      assert Inbox.serialize(entries) == [
               %{
                 "id" => "e1",
                 "from" => "peer",
                 "content" => "from an agent",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "agent",
                 "mode" => nil,
                 "human" => false
               },
               %{
                 "id" => "e2",
                 "from" => "alice",
                 "content" => "from a human",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "user",
                 "mode" => "plan",
                 "human" => true
               },
               %{
                 "id" => "e3",
                 "from" => nil,
                 "content" => "from nobody",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "user",
                 "mode" => nil,
                 "human" => false
               },
               %{
                 "id" => "e4",
                 "from" => "peer",
                 "content" => "a question",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "query",
                 "mode" => nil,
                 "human" => false
               },
               %{
                 "id" => "e5",
                 "from" => nil,
                 "content" => "a notice",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "notice",
                 "mode" => nil,
                 "human" => false
               }
             ]
    end

    test "batch/1 delivers a human head alone and a leading agent run together" do
      # intentional: a human message is delivered alone — it never merges into
      # a batch and nothing merges into it (issue #31 decision 8) — so a queued
      # human message keeps its own turn and its own mode, while peer traffic
      # still batches. The selection only ever takes a prefix, so the FIFO
      # order is untouched.
      alice = entry(:user, "alice", "human note", "plan")
      peer = entry(:agent, "peer", "peer note")
      bob = entry(:agent, "bob", "second peer note")

      assert Inbox.batch([alice, peer, bob]) == [alice]
      assert Inbox.batch([peer, bob, alice]) == [peer, bob]
      assert Inbox.batch([peer, alice, bob]) == [peer]
      assert Inbox.batch([]) == []

      # A kind that is neither `:agent` nor `:user` — `:query` is what W2
      # introduces — batches with peer entries instead of raising: the
      # selection is total on purpose, so a new entry kind cannot crash the
      # drain inside the Agent process.
      query = %{entry(:agent, "peer", "query note") | kind: :query}
      notice = %{entry(:agent, nil, "runtime note") | kind: :notice}

      assert Inbox.batch([query, bob]) == [query, bob]
      assert Inbox.batch([peer, query, alice]) == [peer, query]
      assert Inbox.batch([notice, bob]) == [notice, bob]
      assert Inbox.batch([peer, notice, alice]) == [peer, notice]

      # The invariant the removed `prune_retrieved/1` used to mop up after: a
      # non-empty queue always selects a non-empty batch, so the drain can never
      # peek `:empty` while entries are still queued. A new `select_batch/1`
      # clause that skipped a head would strand the queue instead.
      for queued <- [alice, peer, query, notice] do
        assert Inbox.batch([queued]) != []
      end
    end

    test "deliver_user_message/4 normalizes a non-binary sender and mode to nil" do
      # intentional: `serialize/1`'s contract is string-or-null, so a malformed
      # payload cannot put a number/map on the wire.
      state = %Agent{name: "wire-shape", space_id: 1}

      {state, disposition} = Inbox.deliver_user_message(state, %{"not" => "a string"}, "hi", 123)

      # The idle machine cannot background anything, so the entry stays queued.
      assert disposition == :queued
      assert [%{from: nil, mode: nil, content: "hi", kind: :user}] = state.live.inbox

      assert [serialized] = Inbox.serialize(state.live.inbox)
      assert serialized["from"] == nil
      assert serialized["mode"] == nil
      assert serialized["kind"] == "user"
      assert serialized["content"] == "hi"
      assert is_binary(serialized["timestamp"])
    end

    test "enqueue_internal/4 queues the runtime's own result for any kind, even at the cap" do
      # intentional: the cap exists to bound a runaway *peer* producer, so the
      # runtime enqueuing its own result (W2's async spawn/batch completion,
      # and the give-up notice) must never be refused by its own cap — it
      # always queues and broadcasts, exactly like the human path.
      full = for n <- 1..100, do: entry(:agent, "peer", "msg #{n}")
      state = %Agent{name: "internal", space_id: 1}
      state = %{state | live: %{state.live | inbox: full}}
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      Enum.reduce(Enum.with_index([:agent, :query, :notice], 101), state, fn {kind, n}, state ->
        content = "runtime says #{n}"
        state = Inbox.enqueue_internal(state, "runtime", content, kind)

        assert length(state.live.inbox) == n

        # The frame is the delta for this enqueue: the one entry it appended
        # (issue #27), not the 100 already queued.
        assert_receive {:chat_inbox, %{op: "append", count: ^n, messages: [entry]}}
        assert entry["content"] == content
        assert entry["kind"] == Atom.to_string(kind)

        assert %{from: "runtime", content: ^content, kind: ^kind, mode: nil} =
                 List.last(state.live.inbox)

        state
      end)
    end

    test "query_senders/1 selects only named query senders" do
      # intentional: the obligation is keyed by name, so an unnamed query owes
      # nothing, and only a `:query` entry is a question that expects an answer.
      # Total like `batch/1`: `nil` is the chat-request path's "no batch".
      entries = [
        entry(:agent, "peer", "not a question"),
        entry(:query, "alice", "ask alice"),
        entry(:query, nil, "no sender"),
        entry(:query, "", "blank sender"),
        entry(:notice, "peer", "runtime notice")
      ]

      assert Inbox.query_senders(entries) == ["alice"]
      assert Inbox.query_senders([]) == []
      assert Inbox.query_senders(nil) == []
    end

    test "drain_mode/1 picks the most recent entry that names a mode" do
      # intentional: `drain_mode/1` is total over any entry list and returns the
      # most recent entry's mode, `nil` meaning "leave the agent's mode alone".
      # A mode rides a *message* — the human's own request on a `:user` entry,
      # and a peer's `set_mode` on an `:agent` one — so either kind can name one.
      # A real batch is either a lone human entry or a run of leading non-human
      # ones (`Inbox.batch/1`), so the mixed lists below are defensive-input
      # coverage for the rule, not a shape a drain can produce.
      assert Inbox.Mode.drain_mode([entry(:agent, "peer", "no mode")]) == nil
      assert Inbox.Mode.drain_mode([entry(:user, "alice", "plan", "plan")]) == "plan"

      # A peer's `set_mode` counts too: the change rides the message it belongs
      # to, so an agent entry naming a mode is a change the drain applies.
      assert Inbox.Mode.drain_mode([entry(:agent, "peer", "peer note", "plan")]) == "plan"

      assert Inbox.Mode.drain_mode([
               entry(:user, "alice", "plan", "plan"),
               entry(:agent, "peer", "no mode"),
               entry(:user, "bob", "review", "review")
             ]) == "review"

      assert Inbox.Mode.drain_mode([
               entry(:user, "alice", "plan", "plan"),
               entry(:user, "bob", "no mode"),
               entry(:agent, "peer", "no mode")
             ]) == "plan"

      assert Inbox.Mode.drain_mode([
               entry(:user, "alice", "no mode"),
               entry(:agent, "peer", "peer note", "plan")
             ]) == "plan"
    end
  end

  describe "delivery ids and consume semantics (issue #62)" do
    test "every enqueued entry carries a distinct id" do
      # intentional: the id is a per-delivery identity, not a sequence, so two
      # enqueues in the same millisecond never collide on the wire or in an
      # `agent-inbox-<id>.txt` filename.
      state = %Agent{name: "ids", space_id: 1}

      state = Inbox.enqueue_internal(state, "peer", "one", :agent)
      state = Inbox.enqueue_internal(state, "peer", "two", :agent)

      ids = Enum.map(state.live.inbox, & &1.id)
      assert length(Enum.uniq(ids)) == 2
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))
    end

    test "consume/2 drops exactly the delivered batch and leaves the rest" do
      peer = entry(:agent, "peer", "peer note", nil, "a")
      human = entry(:user, "alice", "human note", "plan", "b")

      assert Inbox.consume([peer, human], [peer]) == [human]
      assert Inbox.consume([peer, human], []) == [peer, human]
      assert Inbox.consume([peer, human], [peer, human]) == []
    end
  end

  defp entry(kind, from, content, mode \\ nil, id \\ nil) do
    %{
      id: id || Inbox.new_id(),
      from: from,
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: mode,
      human?: false,
      fulfilled_ids: []
    }
  end
end
