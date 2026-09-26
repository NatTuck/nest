defmodule Nest.Agents.Agent.MessageAppender do
  @moduledoc """
  Handles the `Agent`'s `:append_message` and `:append_messages`
  GenServer calls.

  The single-message variant
  (`handle_call({:append_message, message}, ...)`) appends one
  message and returns the stamped result. The batch variant
  (`handle_call({:append_messages, messages}, ...)`) appends a
  list of messages in one mailbox round-trip.

  ## Atomicity (the batch variant)

  The batch variant exists to close a wire-format regression:
  when a caller (e.g., the Case 2 notice injector in
  `Nest.Agents.Agent.ChatTurn.NoticeInjector`) needs to land
  a synthetic pair like `[assistant(attention), user(notice)]`
  in the Agent's messages list, doing it via two sequential
  `{:append_message, _}` calls leaves the messages list
  half-updated if the second call times out (the Agent's
  mailbox can be slow under DB load, and the second reply can
  come back after the per-call `5_000ms` budget). The Agent
  process serializes messages, so a single
  `{:append_messages, _}` call means the messages list is
  either fully updated (all stamped) or fully untouched.

  ## Sequence repair (prevent)

  Every live append flows through here, so this is where the
  append-time half of the sequence invariants lives. Before the
  requested message lands, `MessageList.pairing_bridge/2` is asked
  for repair messages: when the tail is an assistant with an
  unpaired `tool_use`, a synthetic `is_error` tool result (and, for
  an incoming user message, an assistant acknowledgement so
  alternation holds) is appended and persisted first. This is what
  makes the `visual-possum-root` orphan impossible on the live path;
  see `notes/enforce-mesages-seq-invariants.md`.

  ## Loop-breaker reset

  Both handlers reset `consecutive_compaction_count` to zero
  when an appended message is genuine progress (`:user`,
  `:assistant`, or `:tool`). Repair messages are part of the
  requested append and do not change the reset decision (which is
  taken from the caller's requested messages).

  ## In-process entry point

  `__append_messages__/2` is the in-process twin of the batch
  handler. Same atomicity guarantee (a single state mutation),
  no mailbox round-trip. Used by the Case C pipeline injector
  in `Nest.Agents.Agent.ChatPipeline` (which runs inside the
  Agent process and can't GenServer.call itself).
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Messages.MessageList
  alias Nest.Tokens.PreFlight

  @doc """
  `handle_call/3` for the single-message case. Resets the
  loop-breaker counter on genuine progress, then appends via
  `append_one/2` and returns `{stamped, new_state}`.
  """
  @spec handle_single(Agent.t(), {atom(), map()}) :: {term(), Agent.t()}
  def handle_single(state, message) do
    state = if progress_message?(message), do: reset_consecutive(state), else: state
    append_one(state, message)
  end

  @doc """
  `handle_call/3` for the batch case. Resets the loop-breaker
  counter once if any message is genuine progress, then appends each
  via `append_with_bridge/2` in input order. Returns every stamped
  message, including any repair messages.
  """
  @spec handle_batch(Agent.t(), [{atom(), map()}]) :: {[term()], Agent.t()}
  def handle_batch(state, messages) do
    state =
      if Enum.any?(messages, &progress_message?/1), do: reset_consecutive(state), else: state

    Enum.reduce(messages, {[], state}, fn message, {acc, state} ->
      {stamped, state} = append_with_bridge(state, message)
      {acc ++ stamped, state}
    end)
  end

  @doc """
  In-process batch append. Same atomicity guarantee as
  `handle_batch/2` without paying the round-trip cost for
  callers that already run inside the Agent process.

  Returns `{stamped_messages, new_state}`. The loop-breaker
  counter resets if any message in the batch is genuine
  progress; otherwise the counter is preserved.
  """
  @spec append_in_process(Agent.t(), [{atom(), map()}]) :: {[term()], Agent.t()}
  def append_in_process(state, messages) do
    handle_batch(state, messages)
  end

  @doc """
  Stamp and append a single message to the in-memory state.
  Index comes from `state.chat_state.next_message_index`;
  after stamping, the index is bumped and the message is
  broadcast + persisted. Returns `{stamped_message, new_state}`.

  Any sequence-repair messages required before this one are
  appended first (see the moduledoc); this still returns only the
  requested stamped message.

  Choke point: no message is stored from a conversation that
  has not passed the pre-flight decision. `PreFlight.ensure_passed!/2`
  raises if `state.chat_state.messages` is `:cannot_compact`, so a
  message is never appended into an unrecoverable conversation.
  `state.llm_metrics.context_limit` is resolved eagerly at agent
  init (never nil); the guard clause below enforces that too.
  """
  @spec append_one(Agent.t(), {atom(), map()}) :: {term(), Agent.t()}
  def append_one(state, message) do
    {stamped, state} = append_with_bridge(state, message)
    {List.last(stamped), state}
  end

  @doc """
  Stamp and append a single message to `state.chat_state.history`
  (instead of `messages`). Index still comes from
  `state.chat_state.next_message_index` — appending to history
  consumes the same index slot as appending to messages; both
  are parts of the combined `history ++ messages` sequence.

  Used for messages that should never be sent to the LLM
  (the compaction marker): they live in history only but still
  consume an index slot in the DB so the on-demand-load path
  can reconstruct the boundary.

  Does NOT broadcast `chat:message` — the marker's broadcast
  path is `chat:compaction` (carries the marker + history),
  which the caller fires separately via
  `Nest.Agents.Agent.Broadcasts.compaction/3`. Does NOT call
  `reset_consecutive/1` — archiving a marker is not a "progress"
  signal. History appends are exempt from the sequence repair
  (the invariant is on the LLM-facing `messages` sequence).

  Returns `{stamped_message, new_state}`.
  """
  @spec append_history_one(Agent.t(), {atom(), map()}) :: {term(), Agent.t()}
  def append_history_one(%{llm_metrics: %{context_limit: limit}} = state, message)
      when is_integer(limit) and limit > 0 do
    PreFlight.ensure_passed!(state.chat_state.messages, limit)
    index = state.chat_state.next_message_index
    stamped = put_message_index(message, index)

    history = (state.chat_state.history || []) ++ [stamped]

    state = %{
      state
      | chat_state: %{state.chat_state | history: history, next_message_index: index + 1}
    }

    AgentPersistence.append_message(
      state.space_id,
      state.name,
      stamped,
      state.chat_state.next_message_index
    )

    {stamped, state}
  end

  # Append the sequence-repair messages (if any) followed by the
  # requested message, all through one state mutation. Returns
  # `{[stamped_messages...], new_state}` with the requested message
  # last.
  defp append_with_bridge(state, message) do
    bridge = MessageList.pairing_bridge(state.chat_state.messages, message)

    Enum.reduce(bridge ++ [message], {[], state}, fn msg, {acc, state} ->
      {stamped, state} = append_stamped(state, msg)
      {acc ++ [stamped], state}
    end)
  end

  # The raw stamp/broadcast/persist step. No sequence repair here —
  # `append_with_bridge/2` calls this once per message.
  defp append_stamped(%{llm_metrics: %{context_limit: limit}} = state, message)
       when is_integer(limit) and limit > 0 do
    PreFlight.ensure_passed!(state.chat_state.messages, limit)
    index = state.chat_state.next_message_index
    stamped = put_message_index(message, index)

    messages = state.chat_state.messages ++ [stamped]

    state = %{
      state
      | chat_state: %{state.chat_state | messages: messages, next_message_index: index + 1}
    }

    Broadcasts.message(state, stamped)

    AgentPersistence.append_message(
      state.space_id,
      state.name,
      stamped,
      state.chat_state.next_message_index
    )

    {stamped, state}
  end

  defp put_message_index({role, %{index: _} = msg}, index) do
    {role, %{msg | index: index}}
  end

  defp progress_message?({role, _}) when role in [:user, :assistant, :tool], do: true
  defp progress_message?(_), do: false

  defp reset_consecutive(state) do
    %{state | live: %{state.live | consecutive_compaction_count: 0}}
  end
end
