defmodule Nest.Agents.Agent.InboxSerializationTest do
  @moduledoc """
  The inbox's wire shape and its pure selection/rendering rules: `serialize/1`,
  `batch/1`, `combine_and_offload/2`, the two self-produced enqueues, and
  `drain_mode/1`.

  Split out of `InboxTest` (which owns the delivery/disposition contract) when
  that file reached the credo source-file cap; the behavior contract is carried
  by the tests and their inline `#` comments, exactly as there.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Inbox

  describe "entry shape and serialization" do
    test "serialize/1 emits the wire shape the browser renders, for every kind" do
      # intentional: the channel/browser contract is exactly these five
      # keys; `kind` is the entry's provenance (a peer's words, a query that
      # owes a reply, the runtime speaking for itself, or a human's words) and
      # `mode` carries the human's requested mode (nil for every other kind).
      at = ~U[2026-01-02 03:04:05Z]

      entries = [
        %{from: "peer", content: "from an agent", timestamp: at, kind: :agent, mode: nil},
        %{from: "alice", content: "from a human", timestamp: at, kind: :user, mode: "plan"},
        %{from: nil, content: "from nobody", timestamp: at, kind: :user, mode: nil},
        %{from: "peer", content: "a question", timestamp: at, kind: :query, mode: nil},
        %{from: nil, content: "a notice", timestamp: at, kind: :notice, mode: nil}
      ]

      assert Inbox.serialize(entries) == [
               %{
                 "from" => "peer",
                 "content" => "from an agent",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "agent",
                 "mode" => nil
               },
               %{
                 "from" => "alice",
                 "content" => "from a human",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "user",
                 "mode" => "plan"
               },
               %{
                 "from" => nil,
                 "content" => "from nobody",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "user",
                 "mode" => nil
               },
               %{
                 "from" => "peer",
                 "content" => "a question",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "query",
                 "mode" => nil
               },
               %{
                 "from" => nil,
                 "content" => "a notice",
                 "timestamp" => "2026-01-02T03:04:05Z",
                 "kind" => "notice",
                 "mode" => nil
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
    end

    test "combine_and_offload/2 renders a lone human message bare and labels an agent batch" do
      # intentional: the rendered text is LLM-facing. A human entry is its bare
      # content (its `[mode: X]` prefix is added when the message is built), so
      # a queued human message reads exactly like one that arrived while the
      # agent was idle. Agent entries keep `[Message from agent "X"]`, which is
      # what disambiguates a batch; a missing or blank sender drops the quoted
      # name rather than printing `nil` or `""`.
      state = %Agent{tmp_path: nil}

      assert Inbox.combine_and_offload([entry(:user, "alice", "from a human", "plan")], state) ==
               "from a human"

      assert Inbox.combine_and_offload([entry(:user, nil, "from nobody")], state) ==
               "from nobody"

      assert Inbox.combine_and_offload(
               [
                 entry(:agent, "peer", "from an agent"),
                 entry(:agent, "", "from a blank agent"),
                 entry(:agent, nil, "from nobody")
               ],
               state
             ) ==
               "[Message from agent \"peer\"]\nfrom an agent\n\n" <>
                 "[Message from agent]\nfrom a blank agent\n\n" <>
                 "[Message from agent]\nfrom nobody"

      # A query is a peer's words and keeps the label (decision 7); a notice
      # is the runtime's own and must never be framed as an agent's (decision
      # 9) — it renders bare, exactly like a human's.
      assert Inbox.combine_and_offload([entry(:query, "peer", "may I ask?")], state) ==
               "[Message from agent \"peer\"]\nmay I ask?"

      assert Inbox.combine_and_offload([entry(:notice, "peer", "peer never answered")], state) ==
               "peer never answered"
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
        assert_receive {:chat_inbox, %{count: ^n, messages: messages}}
        assert List.last(messages)["content"] == content
        assert List.last(messages)["kind"] == Atom.to_string(kind)

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

    test "drain_mode/1 picks the most recent human mode and ignores the rest" do
      # intentional: `drain_mode/1` is total over any entry list and returns the
      # most recent human-sourced mode, `nil` meaning "leave the agent's mode
      # alone". A real batch is either a lone human entry or a run of non-human
      # ones (`Inbox.batch/1`), so the mixed lists below are defensive-input
      # coverage for the rule, not a shape a drain can produce.
      assert Inbox.drain_mode([entry(:agent, "peer", "no mode")]) == nil
      assert Inbox.drain_mode([entry(:user, "alice", "plan", "plan")]) == "plan"

      assert Inbox.drain_mode([
               entry(:user, "alice", "plan", "plan"),
               entry(:agent, "peer", "no mode"),
               entry(:user, "bob", "review", "review")
             ]) == "review"

      assert Inbox.drain_mode([
               entry(:user, "alice", "plan", "plan"),
               entry(:user, "bob", "no mode"),
               entry(:agent, "peer", "no mode")
             ]) == "plan"
    end
  end

  defp entry(kind, from, content, mode \\ nil) do
    %{from: from, content: content, timestamp: DateTime.utc_now(), kind: kind, mode: mode}
  end
end
