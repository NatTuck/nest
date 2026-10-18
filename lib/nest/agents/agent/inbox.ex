defmodule Nest.Agents.Agent.Inbox do
  @moduledoc """
  The `Agent`'s queued-message inbox.

  Three producers queue here:

    * an `agents-send` tool call from another agent
      (`Agent.deliver_note/4` → `handle_delivery/4`), recorded with
      `kind: :agent`,
    * a human chat message that arrived while the agent was busy
      (`Agent.chat/5` → `Callbacks.chat_or_queue/5` →
      `deliver_user_message/5`), recorded with `kind: :user`, and
    * the runtime's own result for this agent
      (`enqueue_internal/4`, W2's async spawn/batch completion).

  An entry is `%{id, from, content, timestamp, kind, mode, human?, fulfilled_ids}`.
  `content` is stored **verbatim** (no `[mode: ...]` prefix — that
  is added when the entry is delivered), `mode` is the mode the entry asks the
  recipient to run under — a human's own, or a peer's `set_mode` — and is `nil`
  for an entry that asks for no change, and the producer-supplied fields are
  `human?` (the human's own words) and `fulfilled_ids` (the tool-call ids a
  backgrounded batch's result answers, issue #36), empty for other producers.

  ## Kinds

  `kind` is the *provenance* of an entry, and the delivery path is the
  same for every one of them:

    * `:agent` — a peer's words, delivered as `[Message from agent "X"]`.
    * `:query` — `agents-query`: the same peer framing (the requester is an
      agent, so the target reads it as one), plus a **reply obligation** on
      the target (`Machine.owe_replies/2`, set at delivery).
    * `:runtime` — the runtime speaking for itself, not an agent's words
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
      the message is queued on `state.live.inbox`. A target executing a tool
      batch is the one exception (issue #36): the batch is moved to the
      background, the message is delivered immediately, and the batch's own
      result arrives later as a `:runtime` entry. That deferral is armed from
      the batch's own side too (`Machine.Backgrounding.deferred_actions/1`): a
      batch that *starts* while messages are queued backgrounds itself and
      delivers them (issue #103), so a message that arrived while the model was
      still streaming the response asking for the batch is not left waiting for
      the next arrival. Otherwise the machine drains the queue at the next turn
      boundary: `Transitions.iterate/1` emits the
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
  batch. `Nest.Agents.Agent.Inbox.Render` then renders the batch: a human entry
  is its bare content (so a queued human message reads exactly like one that
  arrived while the agent was idle, and its own `[mode: X]` prefix is added
  when the message is built), a `:runtime` entry is bare because the
  runtime — not an agent — said it, while each `:agent`/`:query` entry keeps
  `[Message from agent "<from>"]` — that label is what disambiguates a batch of
  peer messages — and an unknown sender (`nil`) drops the quoted name rather
  than putting `nil` in the prompt.
  A batch over `Nest.Agents.Agent.Config.configured_async_message_max_tokens/0`
  is written to the agent's scratch dir and replaced by a short pointer telling
  the agent how many messages there were and where to read them.

  ## One mode per delivery

  A delivered batch runs in one mode: the most recent entry that carries a mode
  wins (`drain_mode/1`), whatever its kind — a peer's `set_mode` counts as much
  as a human's — and `nil` leaves the agent's current mode unchanged. Because a human message is delivered alone, that winner is
  simply its own requested mode, so every human message runs in the mode it
  asked for. The winner is resolved at **delivery-attempt time**, against the
  batch actually delivered — the executor applies it when it peeks the queue,
  and a peek that cannot deliver (a compaction) is re-resolved when the resume
  re-drains, so a newer human message that arrives while the agent is compacting
  is delivered in its own mode rather than under an older batch's. An attempt
  that delivers nothing — declined because the context cannot hold the message,
  parked on a compaction, or blocked — puts the mode back
  (`Turn.restore_undelivered_mode/3`), so the winner never sticks for an entry
  that is still queued.

  The executor applies the winning mode when it drains — never when the
  entry is queued, because `state.live.mode` feeds `ctx.mode`/`ctx.caps`,
  which are rebuilt on every settle; setting it on arrival would re-resolve
  the caps of the *ongoing* turn's remaining tool calls. An attempt that
  delivers nothing leaves the mode as it was, for the same reason.

  The inbox is in-memory (`ChatState.Live`), so a BEAM restart drops
  undrained messages. `@max_inbox_size` bounds a runaway *peer* producer
  (`handle_delivery/4`); the two self-produced paths — a human message
  (`deliver_user_message/4`) and the runtime's own result
  (`enqueue_internal/4`) — always queue rather than silently dropping.

  ## The wire is incremental (issue #27)

  Every queue mutation broadcasts one delta describing *that* mutation, never
  the whole list — the frames and their `count`/`inboxSeq` contract are
  `Nest.Agents.Agent.Broadcasts`'s. So `n` queued frames cost `~n·s` bytes
  instead of the `~n²·s/2` a full-list rebroadcast per enqueue costs, and a
  client that misses one re-requests the full list over `chat:inbox` (the
  `op: "replace"` frame, also carried by `init`) instead of ending up silently
  wrong; `chat:status`'s `pendingMessageCount` is the count half of the same
  recovery.

  **Accepted limit: the human path is deliberately unbounded.** A human message
  is never refused by `@max_inbox_size` (only a *peer* producer's is), so the
  queue — and the memory it holds — can grow without bound while the agent is
  busy. The deltas remove the quadratic *traffic*, not the growth; bounding it,
  and rate-limiting the channel event that fills it, is issue #110.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Inbox.Delivery
  alias Nest.Agents.Agent.Inbox.Render
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Timeline
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Agent.Turn.Backgrounded
  alias Nest.Agents.Agent.Watch
  alias Nest.Messages.User

  require Logger

  # Statuses during which an incoming message must queue rather than
  # start a turn. `Machine.status_for/1` maps `:stopping` to `:streaming`,
  # so a message that arrives during a stop queues here and the stop
  # path's `{:drain_inbox}` delivers it.
  @busy_statuses [:streaming, :executing_tools, :compacting]

  # The one busy status whose in-flight work can be moved to the background so
  # the message is delivered *now* (issue #36): a tool batch has no partial
  # state worth waiting for — its real result arrives as a notice either way —
  # while a streaming response and a compaction both keep their message queued.
  # The machine arms the same deferral from the batch's own side, at the moment
  # the batch becomes interruptible (`Machine.Backgrounding.deferred_actions/1`,
  # issue #103), so a message that queued before the batch existed is not left
  # waiting for the next arrival.
  @backgroundable_statuses [:executing_tools]

  # Hard cap on queued agent-sourced messages. When full the sender gets
  # an `:inbox_full` error and nothing is queued.
  @max_inbox_size 100

  @type kind :: :agent | :user | :query | :runtime

  @type entry :: %{
          id: String.t(),
          from: String.t() | nil,
          content: String.t(),
          timestamp: DateTime.t(),
          kind: kind(),
          mode: String.t() | nil,
          human?: boolean(),
          fulfilled_ids: [String.t()]
        }

  @doc """
  True for the statuses where an incoming message queues instead of starting
  a turn. Shared with `Callbacks.chat_or_queue/4` so "busy" has one
  definition.
  """
  @spec busy_status?(atom()) :: boolean()
  def busy_status?(status), do: status in @busy_statuses

  # True for the busy statuses whose in-flight batch is moved to the background
  # for the incoming message instead of queueing behind it (issue #36, decision
  # D3). Status-only, and distinct from `Machine.Backgrounding.backgroundable?/1`
  # despite the shared name: that one asks whether *this* machine can move its
  # batch (a live worker and something left to answer), and the machine answers
  # for itself. Private because `drain_backgroundable/1` is its only reader.
  defp backgroundable?(status), do: status in @backgroundable_statuses

  @doc """
  `handle_call/3` body for `Agent.deliver_note/4` (the `agents-send` and
  `agents-query` paths, and the runtime's own `:runtime`).

  `kind` is the entry's provenance (`t:kind/0`); it is stored on the entry
  and decides only how the entry renders. The disposition is the same for
  every kind.

  Returns the GenServer reply tuple:
    * `{:ok, :delivered}` — the target was idle, or was executing a tool batch
      that the message moved to the background (issue #36), so the message
      reached the transcript.
    * `{:ok, :queued}` — the target was busy and the message is queued (a
      backgrounded delivery that parked leaves it queued, exactly as before).
    * `{:error, reason}` — the target is in a broken state or the inbox
      is full.
  """
  @spec handle_delivery(Agent.t(), String.t(), String.t(), kind(), String.t() | nil) ::
          {:reply, {:ok, :delivered | :queued} | {:error, term()}, Agent.t()}
  def handle_delivery(state, sender, content, kind \\ :agent, mode \\ nil) do
    state = satisfy_watch(state, sender, kind)
    status = Machine.status_for(state.live.machine)

    cond do
      length(state.live.inbox) >= @max_inbox_size ->
        record_inbox(state, :refused, sender, kind, content, disposition: :inbox_full)
        {:reply, {:error, :inbox_full}, state}

      busy_status?(status) ->
        {state, disposition} = busy_delivery(state, sender, content, kind, mode, false)
        {:reply, {:ok, disposition}, state}

      status == :idle ->
        idle_delivery(state, sender, content, kind, mode)

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
  target is idle, drains; like its busy arm it also delivers *now* when the
  target is executing a batch that can be moved to the background (issue #36
  decision D1 — *any* incoming message preempts, the runtime's own included).
  Unlike either, it never refuses, whatever the target's status: the cap exists
  to bound a runaway *peer* producer, and there is no other process to hand an
  error to — refusing would lose the batch's whole output.

  Always replies `{:ok, :delivered | :queued}`: `:delivered` when the drain
  consumed the entry (the target was idle, or its batch was backgrounded),
  `:queued` otherwise.
  """
  @spec deliver_internal(Agent.t(), String.t() | nil, String.t(), kind()) ::
          {:reply, {:ok, :delivered | :queued}, Agent.t()}
  def deliver_internal(state, sender, content, kind) do
    state = satisfy_watch(state, sender, kind)

    if Machine.status_for(state.live.machine) == :idle do
      # The runtime's own result carries no mode: it is an outcome, not a request.
      idle_delivery(state, sender, content, kind, nil)
    else
      {state, disposition} = busy_delivery(state, sender, content, kind, nil, false)
      {:reply, {:ok, disposition}, state}
    end
  end

  # The busy arm, shared by every delivery entry point: queue the entry,
  # broadcast it, and then let `drain_backgroundable/1` deliver it now when the
  # in-flight batch can be moved to the background (issue #36). The disposition
  # the drain resolved is the one the caller reports *and* the one recorded:
  # recording `:queued` before the drain ran would put a `queued` line in the
  # timeline for a delivery the sender was told was `:delivered` (and whose tool
  # result reads "Message delivered to …"). `mode` is the human's requested mode
  # and `nil` for every other producer; it rides the record, so a reader still
  # sees what the human asked for.
  defp busy_delivery(state, sender, content, kind, mode, human?) do
    {state, entry} = put_entry(state, sender, content, kind, mode, human?)
    state = broadcast_append(state, [entry])
    queued_before = length(state.live.inbox)
    {state, disposition} = drain_backgroundable(state)

    record_inbox(state, disposition, sender, kind, content,
      mode: mode,
      count: queued_before,
      disposition: disposition
    )

    {state, disposition}
  end

  # The idle arm: enqueue, drain through the turn executor, and report the
  # disposition the drain resolved.
  defp idle_delivery(state, sender, content, kind, mode) do
    {state, entry} = put_entry(state, sender, content, kind, mode)
    queued_before = length(state.live.inbox)
    {state, result} = Turn.drain_inbox(state)

    # Peek-then-consume (#26): the drain only consumes the queue when it
    # actually appended the message, so a drain that parks it (a compaction
    # it needs, or a `:cannot_compact` block) leaves it queued and reports
    # `:queued`. The busy branch broadcasts on enqueue; this one must not leave
    # the entry reachable only by a client refetch, and it is the *only* frame
    # due when nothing was consumed. A drain that consumed the entry already
    # broadcast its removal — this entry was in that batch — so a second frame
    # here would describe a mutation the client has already applied.
    state = if result == :queued, do: broadcast_append(state, [entry]), else: state

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
  Queue a human chat message on the agent's own inbox and deliver it now when
  the in-flight batch can be moved to the background.

  Called by `Callbacks.chat_or_queue/4` when the agent is busy. `from` is the
  sender identity (the channel passes the socket's username; `nil` is allowed),
  `content` is stored verbatim, and `mode` is the human's requested mode (`nil`
  when the caller picked none). This is the human path's whole busy arm —
  `busy_delivery/5` for a `:user` entry — so the disposition it returns is the
  one the timeline records, exactly as the peer paths do it: recording
  `:queued` before the drain ran would log a queueing for a message the
  transcript already carries.

  Unlike `handle_delivery/4` this never refuses: the sender is a human and
  the cap exists to bound a runaway *peer* producer, so a human message is
  queued even when the cap is reached instead of being silently dropped.

  `human?` rides the entry so `build_drained_message/3` can tag the delivered
  message `origin: "human"` for the Ctrl/Cmd+Up recall list. It defaults to
  `false`: the marker has to be earned, so a caller that forgets leaves the
  message untagged rather than claiming the human typed it.
  """
  @spec deliver_user_message(
          Agent.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil,
          boolean()
        ) ::
          {Agent.t(), :delivered | :queued}
  def deliver_user_message(state, from, content, mode, human? \\ false) do
    busy_delivery(state, from, content, :user, mode, human?)
  end

  # Deliver a just-enqueued entry now when the machine is executing a tool batch
  # (issue #36): the batch moves to the background and the entry lands in the
  # transcript, so the caller reports `:delivered`. Every other busy status keeps
  # its entry queued — the decision belongs to the machine
  # (`Machine.Backgrounding`), which no-ops when there is no batch to move, and a
  # no-op leaves the entry queued and this disposition `:queued`.
  defp drain_backgroundable(state) do
    if backgroundable?(Machine.status_for(state.live.machine)) do
      Turn.drain_inbox(state)
    else
      {state, :queued}
    end
  end

  @doc """
  Queue an entry the runtime produced for this agent itself.

  The cap exists to bound a runaway *peer* producer (`handle_delivery/4`), so
  the runtime's own result — an async spawn/batch completion (W2) — must never
  be refused by its own cap: like the human path this bypasses
  `@max_inbox_size` and always queues, broadcasting the new inbox. `kind`
  distinguishes a peer-shaped result from a human one on the wire; `mode` is
  always `nil` (the runtime asks for no mode).

  `fulfilled_ids` is the one piece of entry metadata a producer supplies: the
  tool-call ids a backgrounded batch's outcome answers (issue #36) — a result's
  own, or the calls a worker's death closes. It rides the entry into the message
  the drain appends (`build_drained_message/3`), which is what lets a later load
  tell a promise that was kept from one the process died with
  (`MessageList.backgrounded_results/1`). Empty for every other producer.
  """
  @spec enqueue_internal(Agent.t(), String.t() | nil, String.t(), kind(), [String.t()]) ::
          Agent.t()
  def enqueue_internal(state, from, content, kind, fulfilled_ids \\ [])
      when kind in [:agent, :user, :query, :runtime] do
    {state, entry} =
      state
      |> satisfy_watch(from, kind)
      |> put_entry(from, content, kind, nil, false, fulfilled_ids)

    state = broadcast_append(state, [entry])

    record_inbox(state, :enqueued, from, kind, content,
      count: length(state.live.inbox),
      disposition: :queued
    )

    state
  end

  @doc """
  Queue a backgrounded batch's outcome as a `:runtime` entry (issue #36).

  The notice's wording is `Turn.Backgrounded`'s (it keys off the outcome and the
  command's own timeout marker); `Inbox` owns the entry and the enqueue. Nothing
  says it: no agent did this, so the entry renders bare (`kind: :runtime`).

  `fulfilled_ids` is the delivery's own — the tool-call ids the notice answers
  or closes (`Backgrounding.fulfilled_ids/1` for a result,
  `Backgrounding.ids_for/2` for a worker's death). It rides the entry onto the
  message the drain appends (`build_drained_message/3`).
  """
  @spec deliver_notice(Agent.t(), term(), [String.t()]) :: Agent.t()
  def deliver_notice(state, outcome, fulfilled_ids) do
    enqueue_internal(state, nil, Backgrounded.notice(outcome), :runtime, fulfilled_ids)
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
  JSON-safe view of the queued entries, for the wire (channel/status)
  and tests. `"kind"` is one of `"agent"`, `"user"`, `"query"`,
  `"runtime"`; `"mode"` is a string or `nil`; `"id"` is the delivery id
  (issue #62); `"human"` is `true` only for a prompt the human typed.

  `"human"` is not derivable from `"kind"`: an `agents-spawn` `query`
  kickoff is also a `"user"` entry, so the flag is what lets a reader tell
  a queued human prompt from a queued kickoff nobody typed.
  """
  @spec serialize([entry()]) :: [map()]
  def serialize(entries) do
    Enum.map(entries, fn entry ->
      %{
        "id" => Map.get(entry, :id),
        "from" => entry.from,
        "content" => entry.content,
        "timestamp" => DateTime.to_iso8601(entry.timestamp),
        "kind" => Atom.to_string(entry.kind),
        "mode" => entry.mode,
        "human" => entry.human?
      }
    end)
  end

  # The LLM-facing rendering of a drain batch lives in `Render` — the seam's
  # single owner — and these delegates keep `Inbox` the one public surface a
  # drain caller reaches for, exactly as the `Delivery` delegates below do for
  # the consume API. The rendering rules are documented there.

  @doc """
  Combine one drain batch and, when over the async-message cap, offload the
  text to the agent's scratch dir. Returns the content string to deliver.
  """
  @spec combine_and_offload([entry()], Agent.t()) :: String.t()
  defdelegate combine_and_offload(entries, state), to: Render

  @doc """
  The user message a drained batch is delivered as: its rendered `content`,
  the drain's `mode`, and the batch's metadata.
  """
  @spec build_drained_message([entry()], String.t(), String.t()) :: {:user, User.t()}
  defdelegate build_drained_message(entries, content, mode), to: Render

  @doc """
  The batch a drain delivers, selected from the FIFO head of `entries`.

  A human message is delivered **alone** — it never merges into a batch and
  nothing merges into it — so a queued human message keeps its own turn, its
  own mode and its own place in the queue (issue #31 decision 8). Peer traffic
  still batches: a run of leading non-human entries is delivered as one
  message. The selection never reorders anything; it only takes a prefix.

  Total over any entry *kind* on purpose: a future kind must not be able to
  crash the drain inside the Agent process, so anything that is not a human
  message batches exactly like a peer message does today — `:agent`, `:query`
  and `:runtime` entries all take the second clause. An entry map with no
  `:kind` key raises rather than batching: that is the entry contract
  (`put_entry/7` always sets it), not a shape the drain has to tolerate.
  """
  @spec batch([entry()]) :: [entry()]
  def batch([%{kind: :user} = head | _rest]), do: [head]
  def batch(entries), do: Enum.take_while(entries, &(&1.kind != :user))

  # The delivery-id and consume API lives in `Delivery` (issue #62); these
  # delegates keep `Inbox` the one public surface for a queued entry.
  defdelegate new_id, to: Delivery
  defdelegate consume(entries, batch), to: Delivery

  @doc """
  The senders a delivered batch obliges this agent to answer: one name per
  `kind: :query` entry in it (issue #31 decision 1 — a name, not a record:
  there is no query id and no requester-side state).

  Total over any entry list — a missing `kind` or `from` contributes nothing —
  and `nil`-tolerant because the chat-request path has no batch behind it. A query entry whose sender is
  missing or blank contributes nothing: the obligation is keyed by name
  (`Machine.owe_replies/2`), so an unnamed sender has no key to owe.
  """
  @spec query_senders([entry()] | nil) :: [String.t()]
  def query_senders(entries) when is_list(entries) do
    for %{kind: :query, from: from} <- entries, is_binary(from) and from != "", do: from
  end

  def query_senders(_entries), do: []

  # ---- private ----

  # A delivery from a watched agent satisfies that watch (issue #62 requirement
  # 1): the caller is being woken by the body, so the bare notice would be a
  # second wake. A human entry never satisfies a watch — a human's name is not a
  # watched agent — so this is kind-gated rather than name-only.
  defp satisfy_watch(state, _sender, :user), do: state
  defp satisfy_watch(state, sender, _kind), do: Watch.satisfy(state, sender)

  # One `inbox` timeline event. The four delivery dispositions and the two
  # enqueue paths carry the same `from`/`kind`/`content` and differ only in what
  # they add to it.
  defp record_inbox(state, action, sender, kind, content, extra) do
    Timeline.inbox(state, action, [from: sender, kind: kind, content: content] ++ extra)
  end

  # `from`/`mode` are normalized here, the single write point, so a malformed
  # payload can never put a number/map on the wire (`serialize/1`'s contract is
  # string-or-null for both). Returns the entry as well as the state: the
  # caller broadcasts it as an append delta, and only the entry — not the whole
  # queue — is what that frame may carry (issue #27).
  defp put_entry(state, from, content, kind, mode, human? \\ false, fulfilled_ids \\ []) do
    entry = %{
      id: Delivery.new_id(),
      from: if(is_binary(from), do: from, else: nil),
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: if(is_binary(mode), do: mode, else: nil),
      human?: human? == true,
      fulfilled_ids: fulfilled_ids
    }

    {%{state | live: %{state.live | inbox: state.live.inbox ++ [entry]}}, entry}
  end

  # The append half of the delta protocol (issue #27): the three enqueue paths
  # — the busy and idle delivery arms and `enqueue_internal/4` — each publish
  # exactly the entry they added, never the queue they added it to.
  defp broadcast_append(state, entries), do: Broadcasts.inbox_append(state, serialize(entries))

  @doc """
  Drop `batch` from the queue and broadcast the ids that went — the consume
  half of peek-then-consume (#26), and the single place the executor's drain
  mutates the queue.
  """
  @spec consume_and_broadcast(Agent.t(), [entry()]) :: Agent.t()
  def consume_and_broadcast(state, batch) do
    before = state.live.inbox
    state = %{state | live: %{state.live | inbox: consume(before, batch)}}
    broadcast_remove(state, Enum.map(before -- state.live.inbox, & &1.id))
  end

  # The removal half of the delta protocol (issue #27): the ids the queue no
  # longer holds, in the order they went.
  defp broadcast_remove(state, ids), do: Broadcasts.inbox_remove(state, ids)
end
