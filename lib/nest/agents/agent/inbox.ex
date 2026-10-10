defmodule Nest.Agents.Agent.Inbox do
  @moduledoc """
  The `Agent`'s queued-message inbox.

  Three producers queue here:

    * an `agents-send` tool call from another agent
      (`Agent.deliver_message/4` → `handle_delivery/4`), recorded with
      `kind: :agent`,
    * a human chat message that arrived while the agent was busy
      (`Agent.chat/4` → `Callbacks.chat_or_queue/4` →
      `enqueue_user_message/4`), recorded with `kind: :user`, and
    * the runtime's own result for this agent
      (`enqueue_internal/4`, W2's async spawn/batch completion).

  An entry is `%{from, content, timestamp, kind, mode}`. `content` is
  stored **verbatim** (no `[mode: ...]` prefix — that is added when the
  entry is delivered) and `mode` is the human's requested mode, always
  `nil` for an `agents-send` entry.

  ## Kinds

  `kind` is the *provenance* of an entry, and the delivery path is the
  same for every one of them:

    * `:agent` — a peer's words, delivered as `[Message from agent "X"]`.
    * `:query` — `agents-query`: the same peer framing (the requester is an
      agent, so the target reads it as one), plus a **reply obligation** on
      the target (`Machine.owe_replies/2`, set at delivery).
    * `:notice` — the runtime speaking for itself, not an agent's words
      (issue #31 decision 9). It is rendered **bare**, never under a
      `[Message from agent …]` label, because no agent said it.
    * `:user` — a human's words, rendered bare (its `[mode: X]` prefix is
      added when the message is built).

  ## Disposition

    * **Idle target** — the message (plus anything already queued) is
      drained through the turn executor
      (`Nest.Agents.Agent.Turn.drain_inbox/1`), the single drain path,
      which delivers `batch/1`'s selection.
    * **Busy target** (`:streaming`, `:executing_tools`, `:compacting`) —
      the message is queued on `state.live.inbox`. The machine drains it at
      the next turn boundary: `Transitions.iterate/1` emits the
      `:drain_inbox` action from `:generating`/`:chat` once the wire
      sequence is complete and nothing is in flight (issue #15), and
      anything still queued when the target reaches `:idle` is drained by
      the `:idle` transition. Either way the drain delivers `batch/1`'s
      selection — see "Delivery" below.
    * **Broken target** (`:model_missing`, `:needs_repair`,
      `:context_overflow`, `:compaction_failed`,
      `:compaction_loop_detected`) — `handle_delivery/4` replies with an
      error and nothing is queued; a human message is dropped, since the
      channel has already told the operator why.

  ## Delivery

  `batch/1` selects what a drain delivers: a human message at the FIFO head is
  delivered **alone**, a run of leading non-human entries is delivered as one
  batch. `combine/1` then renders the batch: a human entry is its bare content
  (so a queued human message reads exactly like one that arrived while the
  agent was idle, and its own `[mode: X]` prefix is added when the message is
  built), a `:notice` is bare because the runtime — not an agent — said it,
  while each `:agent`/`:query` entry keeps `[Message from agent "<from>"]` —
  that label is what disambiguates a batch of peer messages — and an unknown
  sender (`nil`) drops the quoted name rather than putting `nil` in the prompt.
  A batch over `Config.configured_async_message_max_tokens/0` is written to
  the agent's scratch dir and replaced by a short pointer telling the agent
  how many messages there were and where to read them.

  ## One mode per delivery

  A delivered batch runs in one mode: the most recent human-sourced entry that
  carries a mode wins (`drain_mode/1`), and `nil` leaves the agent's current
  mode unchanged. Because a human message is delivered alone, that winner is
  simply its own requested mode, so every human message runs in the mode it
  asked for. The winner is resolved at **delivery-attempt time**, against the
  batch actually delivered — the executor applies it when it peeks the queue,
  and a peek that cannot deliver (a compaction) is re-resolved when the resume
  re-drains, so a newer human message that arrives while the agent is compacting
  is delivered in its own mode rather than under an older batch's.

  The executor applies the winning mode when it drains — never when the
  entry is queued, because `state.live.mode` feeds `ctx.mode`/`ctx.caps`,
  which are rebuilt on every settle; setting it on arrival would re-resolve
  the caps of the *ongoing* turn's remaining tool calls.

  The inbox is in-memory (`ChatState.Live`), so a BEAM restart drops
  undrained messages. `@max_inbox_size` bounds a runaway *peer* producer
  (`handle_delivery/4`); the two self-produced paths — a human message
  (`enqueue_user_message/4`) and the runtime's own result
  (`enqueue_internal/4`) — always queue rather than silently dropping, so each
  enqueue rebroadcasts the whole serialized list.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Timeline
  alias Nest.Agents.Agent.Turn
  alias Nest.Tokens.Estimator

  require Logger

  # Statuses during which an incoming message must queue rather than
  # start a turn. `Machine.status_for/1` maps `:stopping` to `:streaming`,
  # so a message that arrives during a stop queues here and the stop
  # path's `{:drain_inbox}` delivers it.
  @busy_statuses [:streaming, :executing_tools, :compacting]

  # Hard cap on queued agent-sourced messages. When full the sender gets
  # an `:inbox_full` error and nothing is queued.
  @max_inbox_size 100

  @type kind :: :agent | :user | :query | :notice

  @type entry :: %{
          from: String.t() | nil,
          content: String.t(),
          timestamp: DateTime.t(),
          kind: kind(),
          mode: String.t() | nil
        }

  @doc """
  True for the statuses where an incoming message queues instead of starting
  a turn. Shared with `Callbacks.chat_or_queue/4` so "busy" has one
  definition.
  """
  @spec busy_status?(atom()) :: boolean()
  def busy_status?(status), do: status in @busy_statuses

  @doc """
  `handle_call/3` body for `Agent.deliver_message/4` (the `agents-send` and
  `agents-query` paths, and the runtime's own `:notice`).

  `kind` is the entry's provenance (`t:kind/0`); it is stored on the entry
  and decides only how the entry renders. The disposition is the same for
  every kind.

  Returns the GenServer reply tuple:
    * `{:ok, :delivered}` — the target was idle; a turn started.
    * `{:ok, :queued}` — the target was busy (or the turn could not
      start) and the message is queued.
    * `{:error, reason}` — the target is in a broken state or the inbox
      is full.
  """
  @spec handle_delivery(Agent.t(), String.t(), String.t(), kind()) ::
          {:reply, {:ok, :delivered | :queued} | {:error, term()}, Agent.t()}
  def handle_delivery(state, sender, content, kind \\ :agent) do
    status = Machine.status_for(state.live.machine)

    cond do
      length(state.live.inbox) >= @max_inbox_size ->
        record_inbox(state, :refused, sender, kind, content, disposition: :inbox_full)
        {:reply, {:error, :inbox_full}, state}

      busy_status?(status) ->
        state = state |> put_entry(sender, content, kind, nil) |> broadcast()

        record_inbox(state, :queued, sender, kind, content,
          count: length(state.live.inbox),
          disposition: :queued
        )

        {:reply, {:ok, :queued}, state}

      status == :idle ->
        idle_delivery(state, sender, content, kind)

      true ->
        record_inbox(state, :refused, sender, kind, content, disposition: {:status, status})
        {:reply, {:error, {:status, status}}, state}
    end
  end

  @doc """
  `handle_call/3` body for `Agent.deliver_internal/4`: the runtime's own result
  for this agent, delivered from the process that produced it.

  This is `enqueue_internal/4`'s guarantee (the runtime's own result must never
  be refused by the peer cap) for a caller in *another* process — a batch
  coordinator delivering its aggregate — which cannot enqueue into this agent's
  state itself. Like `handle_delivery/4`'s idle arm it queues and, when the
  target is idle, drains; unlike it, it never refuses, whatever the target's
  status: the cap exists to bound a runaway *peer* producer, and there is no
  other process to hand an error to — refusing would lose the batch's whole
  output.

  Always replies `{:ok, :delivered | :queued}`: `:delivered` when the target was
  idle and the drain consumed the entry, `:queued` otherwise.
  """
  @spec deliver_internal(Agent.t(), String.t() | nil, String.t(), kind()) ::
          {:reply, {:ok, :delivered | :queued}, Agent.t()}
  def deliver_internal(state, sender, content, kind) do
    if Machine.status_for(state.live.machine) == :idle do
      idle_delivery(state, sender, content, kind)
    else
      state = state |> put_entry(sender, content, kind, nil) |> broadcast()

      record_inbox(state, :queued, sender, kind, content,
        count: length(state.live.inbox),
        disposition: :queued
      )

      {:reply, {:ok, :queued}, state}
    end
  end

  # The idle arm: enqueue, drain through the turn executor, and report the
  # disposition the drain resolved.
  defp idle_delivery(state, sender, content, kind) do
    state = put_entry(state, sender, content, kind, nil)
    queued_before = length(state.live.inbox)
    {state, result} = Turn.drain_inbox(state)

    # Peek-then-consume (#26): the drain only consumes the queue when it
    # actually appended the message, so a drain that parks it (a compaction
    # it needs, or a `:cannot_compact` block) leaves it queued. The busy
    # branch broadcasts on enqueue; this one must not leave the entry
    # reachable only by a client refetch. The consume only ever *removes*
    # entries, so an unchanged length means nothing was consumed: this
    # entry is still queued and this frame is the only way the client learns
    # about it. When the consume did run it has already broadcast the
    # remainder — this entry included — so broadcasting here would send a
    # duplicate frame.
    state =
      if length(state.live.inbox) == queued_before, do: broadcast(state), else: state

    # `result` is the disposition the sender is given, and the action the
    # entry took: a drain that parked the message queued it, so it is
    # recorded as `queued` and not as a delivery that did not happen.
    record_inbox(state, result, sender, kind, content,
      count: queued_before,
      disposition: result
    )

    {:reply, {:ok, result}, state}
  end

  @doc """
  Queue a human chat message on the agent's own inbox.

  Called by `Callbacks.chat_or_queue/4` when the agent is busy. `from` is
  the sender identity (the channel passes the socket's username; `nil` is
  allowed), `content` is stored verbatim, and `mode` is the human's
  requested mode (`nil` when the caller picked none). Broadcasts the new
  inbox and returns the updated state.

  Unlike `handle_delivery/4` this never refuses: the sender is a human and
  the cap exists to bound a runaway *peer* producer, so a human message is
  queued even when the cap is reached instead of being silently dropped.
  """
  @spec enqueue_user_message(Agent.t(), String.t() | nil, String.t(), String.t() | nil) ::
          Agent.t()
  def enqueue_user_message(state, from, content, mode) do
    state = state |> put_entry(from, content, :user, mode) |> broadcast()

    record_inbox(state, :enqueued, from, :user, content,
      mode: mode,
      count: length(state.live.inbox),
      disposition: :queued
    )

    state
  end

  @doc """
  Queue an entry the runtime produced for this agent itself.

  The cap exists to bound a runaway *peer* producer (`handle_delivery/4`), so
  the runtime's own result — an async spawn/batch completion (W2) — must never
  be refused by its own cap: like the human path this bypasses
  `@max_inbox_size` and always queues, broadcasting the new inbox. `kind`
  distinguishes a peer-shaped result from a human one on the wire; `mode` is
  always `nil` (the runtime asks for no mode).
  """
  @spec enqueue_internal(Agent.t(), String.t() | nil, String.t(), kind()) :: Agent.t()
  def enqueue_internal(state, from, content, kind)
      when kind in [:agent, :user, :query, :notice] do
    state = state |> put_entry(from, content, kind, nil) |> broadcast()

    record_inbox(state, :enqueued, from, kind, content,
      count: length(state.live.inbox),
      disposition: :queued
    )

    state
  end

  @doc """
  Log the reply obligations this agent loses with its process.

  Two kinds of loss, both in-process state that goes away with the process:

    * a **debt** (`Machine.owed_replies`) — a query that was delivered, so the
      requester is owed an answer and its `agents-wait` simply times out;
    * a **queued `:query` entry** — a query that was never delivered, so it set
      no debt at all (issue #31 §1.3: the obligation is incurred at delivery)
      and no give-up will ever fire for it. The requester waits for an answer
      that cannot come, and this warning is the only trace of it.

  A stop — an archive, a reload, a crash, a supervisor shutdown — is the
  accepted disposition for a process that is going away (issue #31 decision
  12), but the server log must show what went with it.
  """
  @spec log_lost_replies(Agent.t()) :: :ok
  def log_lost_replies(state) do
    warn_unpaid_replies(state, Machine.owed_senders(state.live.machine))
    warn_queued_queries(state, queued_query_senders(state))
  end

  defp warn_unpaid_replies(_state, []), do: :ok

  defp warn_unpaid_replies(state, senders) do
    Logger.warning(
      "[agent:#{state.name}] stopping with unpaid replies to #{inspect(senders)}: " <>
        "the obligation is in-process state and is lost"
    )
  end

  defp warn_queued_queries(_state, []), do: :ok

  defp warn_queued_queries(state, senders) do
    Logger.warning(
      "[agent:#{state.name}] stopping with undelivered queued queries from " <>
        "#{inspect(senders)}: the queue is in-process state and is lost"
    )
  end

  # One name per requester with a query still queued (a sender that queued two
  # has one loss), sorted so the line is stable.
  defp queued_query_senders(state) do
    state.live.inbox |> query_senders() |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  The mode a drain batch runs in: the most recent human-sourced entry that
  carries a mode wins, and `nil` (no such entry) leaves the agent's current
  mode unchanged. Since `batch/1` delivers a human message alone, that is
  simply its own requested mode. The winner is the *requested* mode; the
  executor's drain resolves it against the vocation (falling back to the
  vocation's default mode) before storing it, exactly as an idle chat turn
  resolves its request.
  """
  @spec drain_mode([entry()]) :: String.t() | nil
  def drain_mode(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{kind: :user, mode: mode} when is_binary(mode) -> mode
      _ -> nil
    end)
  end

  @doc """
  JSON-safe view of the queued entries, for the wire (channel/status)
  and tests. `"kind"` is one of `"agent"`, `"user"`, `"query"`,
  `"notice"`; `"mode"` is a string or `nil`.
  """
  @spec serialize([entry()]) :: [map()]
  def serialize(entries) do
    Enum.map(entries, fn entry ->
      %{
        "from" => entry.from,
        "content" => entry.content,
        "timestamp" => DateTime.to_iso8601(entry.timestamp),
        "kind" => Atom.to_string(entry.kind),
        "mode" => entry.mode
      }
    end)
  end

  @doc """
  Combine one drain batch and, when over the async-message cap, offload the
  text to the agent scratch dir. Returns the content string to deliver.
  Used by the turn executor's drain actions, which pass `batch/1`'s selection
  so the entries rendered are exactly the entries consumed.
  """
  @spec combine_and_offload([entry()], Agent.t()) :: String.t()
  def combine_and_offload(entries, state) do
    offload(combine(entries), entries, state)
  end

  @doc """
  The batch a drain delivers, selected from the FIFO head of `entries`.

  A human message is delivered **alone** — it never merges into a batch and
  nothing merges into it — so a queued human message keeps its own turn, its
  own mode and its own place in the queue (issue #31 decision 8). Peer traffic
  still batches: a run of leading non-human entries is delivered as one
  message. The selection never reorders anything; it only takes a prefix.

  Total over any entry list on purpose: a future entry kind must not be
  able to crash the drain inside the Agent process, so anything that is
  not a human message batches exactly like a peer message does today —
  `:agent`, `:query` and `:notice` entries all take the second clause.
  """
  @spec batch([entry()]) :: [entry()]
  def batch([%{kind: :user} = head | _rest]), do: [head]
  def batch(entries), do: Enum.take_while(entries, &(&1.kind != :user))

  @doc """
  The senders a delivered batch obliges this agent to answer: one name per
  `kind: :query` entry in it (issue #31 decision 1 — a name, not a record:
  there is no query id and no requester-side state).

  Total over any entry list, like `batch/1`, and `nil`-tolerant because the
  chat-request path has no batch behind it. A query entry whose sender is
  missing or blank contributes nothing: the obligation is keyed by name
  (`Machine.owe_replies/2`), so an unnamed sender has no key to owe.
  """
  @spec query_senders([entry()] | nil) :: [String.t()]
  def query_senders(entries) when is_list(entries) do
    for %{kind: :query, from: from} <- entries, is_binary(from) and from != "", do: from
  end

  def query_senders(_entries), do: []

  # ---- private ----

  # One `inbox` timeline event. The four delivery dispositions and the two
  # enqueue paths carry the same `from`/`kind`/`content` and differ only in what
  # they add to it.
  defp record_inbox(state, action, sender, kind, content, extra) do
    Timeline.inbox(state, action, [from: sender, kind: kind, content: content] ++ extra)
  end

  # `from`/`mode` are normalized here, the single write point, so a malformed
  # payload can never put a number/map on the wire (`serialize/1`'s contract is
  # string-or-null for both).
  defp put_entry(state, from, content, kind, mode) do
    entry = %{
      from: if(is_binary(from), do: from, else: nil),
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: if(is_binary(mode), do: mode, else: nil)
    }

    %{state | live: %{state.live | inbox: state.live.inbox ++ [entry]}}
  end

  defp broadcast(state) do
    Broadcasts.inbox(state, serialize(state.live.inbox))
    state
  end

  # The LLM-facing rendering of one drain batch. A human entry is rendered as
  # its bare content — plus, later, the `[mode: X]\n` prefix
  # `Dispatch.build_user_message/2` adds — because a queued human message must
  # read exactly like one that arrived while the agent was idle (issue #31
  # decision 8): the model never has to reason about whether it was queued.
  # A `:notice` is bare for a different reason: it is the runtime speaking,
  # and a `[Message from agent "X"]` label would impersonate X (decision 9).
  # Every other kind keeps its `[Message from agent "X"]` label, which is what
  # disambiguates a batch of peer messages (from each other and from a human's)
  # — including a `:query`, whose requester really is that agent (decision 7).
  defp combine(entries) do
    Enum.map_join(entries, "\n\n", fn
      %{kind: kind, content: content} when kind in [:user, :notice] -> content
      %{content: content} = entry -> "#{agent_label(entry)}\n#{content}"
    end)
  end

  # The LLM-facing label for one `:agent` entry. A missing or blank sender
  # drops the quoted name rather than putting `nil`/`""` in the prompt.
  defp agent_label(%{from: from}), do: "[Message from agent#{quoted(from)}]"

  defp quoted(from) when is_binary(from) and from != "", do: " \"#{from}\""
  defp quoted(_from), do: ""

  # Over the configured cap, write the full combined text to the agent's
  # scratch dir and return a pointer. If the write fails, fall back to
  # the full text so no messages are lost.
  defp offload(content, entries, state) do
    if Estimator.estimate(content) > Config.configured_async_message_max_tokens() do
      case Overflow.write(content, %{tmp_path: state.tmp_path}, "agent-inbox", "txt") do
        nil -> content
        path -> pointer(length(entries), path)
      end
    else
      content
    end
  end

  defp pointer(1, path) do
    "You have 1 queued message. It was too large to " <>
      "include inline and was saved to #{path}. Read that file to see it."
  end

  defp pointer(n, path) do
    "You have #{n} queued messages. They were too large to " <>
      "include inline and were saved to #{path}. Read that file to see them."
  end
end
