defmodule Nest.Agents.Agent.MessageAppender do
  @moduledoc """
  Handles the `Agent`'s message-append entry points.

  The single-message variant appends one message; the batch variant
  appends a list of messages in one mailbox round-trip.

  ## Tagged results

  An append never raises on a sequence mismatch. Every entry point
  returns one of:

      {:ok, stamped_message_or_messages, state}
      {:stale, state}
      {:invalid, reason, state}

  `:stale` (a tool result that does not answer the live tail) is dropped
  with a warning; `:invalid` (a genuinely broken live sequence, or a
  list that fails the `:cannot_compact` send/store tripwire) is dropped
  and the caller fails the turn cleanly. The decision itself lives in
  `Nest.Agents.Agent.Repair`; this module only applies it. Appends never
  raise: the pre-flight tripwire is surfaced as `:invalid`, not an
  exception.

  ## Atomicity (the batch variant)

  The batch variant exists to close a wire-format regression: when a
  caller needs to land a synthetic pair like
  `[assistant(attention), user(notice)]`, doing it via two sequential
  appends leaves the messages list half-updated if the second call times
  out. A single batch call means the messages list is either fully
  updated (all stamped) or untouched.

  ## Live vs terminal

  While a turn is live (`:streaming`, `:executing_tools`, `:compacting`)
  the turn owns the sequence: `Repair.decide(:live, ...)` classifies the
  append and this module only repairs the single shape `Repair` allows —
  an incoming `user` message onto a wire-`user` tail, which is either the
  turn-opening append or the turn-boundary inbox delivery (issue #15).
  At a terminal boundary (idle/stopping/blocked)
  `Repair.decide(:terminal, ...)` heals the tail with
  `MessageList.pairing_bridge/2` before the requested message lands.

  ## Loop-breaker reset

  Both single and batch handlers reset `consecutive_compaction_count` to
  zero when an appended message is genuine progress (`:user`,
  `:assistant`, or `:tool`). Repair messages are part of the requested
  append and do not change the reset decision.

  ## In-process entry points

  `__append_messages__/2` is the in-process twin of the batch handler
  and `__append_message__/2` of the single handler: same guarantee, no
  mailbox round-trip.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Agents.Agent.Repair
  alias Nest.Messages.Sanitize
  alias Nest.Tokens.PreFlight

  # A turn owns the sequence while the machine is `:generating` or
  # `:executing_tools`, so `Repair.decide(:live, ...)` classifies the
  # append instead of healing it — except the one shape `Repair` permits
  # on the live path (a user message onto a wire-user tail: the
  # turn-opening append or the turn-boundary inbox delivery, issue #15).
  # The compactor's `:committing` phase is terminal for repair purposes:
  # the compactor turn is over and the commit writes a fresh segment, so
  # the tail may need a bridge (the legacy commit reset to idle before
  # appending for the same reason).
  @live_phases [:generating, :executing_tools]

  @type append_result ::
          {:ok, term() | [term()], Agent.t()}
          | {:stale, Agent.t()}
          | {:invalid, String.t(), Agent.t()}

  @doc """
  Single-message append: reset the loop-breaker counter on genuine
  progress, then append. Returns the tagged result.
  """
  @spec handle_single(Agent.t(), {atom(), map()}) :: append_result()
  def handle_single(state, message) do
    state = if progress_message?(message), do: reset_consecutive(state), else: state
    append_one(state, message)
  end

  @doc """
  Batch append: reset the loop-breaker counter once if any message is
  genuine progress, then append each in input order. Returns every
  stamped message (including terminal repair messages).
  """
  @spec handle_batch(Agent.t(), [{atom(), map()}]) :: append_result()
  def handle_batch(state, messages) do
    state =
      if Enum.any?(messages, &progress_message?/1), do: reset_consecutive(state), else: state

    Enum.reduce_while(messages, {:ok, [], state}, fn message, {:ok, acc, state} ->
      case append_with_bridge(state, message) do
        {:ok, stamped, state} -> {:cont, {:ok, acc ++ stamped, state}}
        {:stale, state} -> {:halt, {:stale, state}}
        {:invalid, reason, state} -> {:halt, {:invalid, reason, state}}
      end
    end)
  end

  @doc """
  In-process batch append: same atomicity guarantee as `handle_batch/2`
  without the round-trip.
  """
  @spec append_in_process(Agent.t(), [{atom(), map()}]) :: append_result()
  def append_in_process(state, messages), do: handle_batch(state, messages)

  @doc """
  In-process single append: stamp and append the requested message,
  returning `{:ok, stamped_message, state}`. Repair messages required at
  a terminal boundary are appended first; the requested message is the
  one returned.
  """
  @spec append_one(Agent.t(), {atom(), map()}) :: append_result()
  def append_one(state, message) do
    case append_with_bridge(state, message) do
      {:ok, stamped, state} -> {:ok, List.last(stamped), state}
      {:stale, state} -> {:stale, state}
      {:invalid, reason, state} -> {:invalid, reason, state}
    end
  end

  @doc """
  Stamp and persist the compaction marker, which *is* the new
  `last_compaction_index`: the marker consumes a real index slot and the
  boundary moves to it, so the marker lands on the archived side of the
  partition and never in the LLM-facing `messages`.

  Markers are exempt from sequence repair (the invariant is on the
  LLM-facing sequence). Returns `{:ok, stamped_message, state}` or
  `{:invalid, reason, state}` if the marker list fails the tripwire.
  """
  @spec append_marker(Agent.t(), {atom(), map()}) ::
          {:ok, term(), Agent.t()} | {:invalid, String.t(), Agent.t()}
  def append_marker(%{llm_metrics: %{context_limit: limit}} = state, message)
      when is_integer(limit) and limit > 0 do
    case PreFlight.check_passed(state.chat_state.messages, limit) do
      :ok ->
        index = state.chat_state.next_message_index
        stamped = put_message_index(message, index)

        state = %{
          state
          | chat_state: %{
              state.chat_state
              | last_compaction_index: index,
                compaction_count: state.chat_state.compaction_count + 1,
                next_message_index: index + 1
            }
        }

        AgentPersistence.append_message(
          state.space_id,
          state.name,
          stamped,
          state.chat_state.next_message_index
        )

        {:ok, stamped, state}

      {:error, reason} ->
        {:invalid, reason, state}
    end
  end

  # Append the requested message. While a turn is live the sequence is
  # owned by that turn and repair is limited to the one shape `Repair`
  # allows on the live path: this module must not race the turn, and in
  # particular it never fabricates a `tool_result` (the machine does that
  # itself when it backgrounds an in-flight batch — issue #36 — and emits
  # it as an explicit action). At a terminal boundary the sequence is
  # healed before the requested message lands.
  defp append_with_bridge(state, message) do
    if live_turn?(state) do
      append_live(state, message)
    else
      {:repair, repair_messages} =
        Repair.decide(:terminal, state.chat_state.messages, message)

      append_messages(state, repair_messages ++ [message])
    end
  end

  defp append_live(state, message) do
    case Repair.decide(:live, state.chat_state.messages, message) do
      :ok -> append_messages(state, [message])
      :stale -> drop_stale(state, message)
      {:repair, repair} -> append_messages(state, repair ++ [message])
      {:invalid, reason} -> {:invalid, reason, state}
    end
  end

  defp drop_stale(state, _message) do
    Logger.warning(
      "[agent:#{state.name}] dropping a stale append (status=" <>
        "#{Machine.status_for(state.live.machine)}): it does not answer the live sequence"
    )

    {:stale, state}
  end

  defp append_messages(state, messages) do
    Enum.reduce_while(messages, {:ok, [], state}, fn message, {:ok, acc, state} ->
      case append_stamped(state, message) do
        {:ok, stamped, state} -> {:cont, {:ok, acc ++ [stamped], state}}
        {:invalid, reason, state} -> {:halt, {:invalid, reason, state}}
      end
    end)
  end

  defp live_turn?(state), do: state.live.machine.phase in @live_phases

  # The raw stamp/broadcast/persist step. No sequence repair here.
  # Returns `{:ok, stamped, state}` or `{:invalid, reason, state}` when
  # the current list trips the `:cannot_compact` pre-flight guard (the
  # caller fails the turn cleanly rather than raising).
  defp append_stamped(%{llm_metrics: %{context_limit: limit}} = state, message)
       when is_integer(limit) and limit > 0 do
    # NUL and invalid UTF-8 (raw shell/file bytes) cannot be stored in
    # jsonb and would crash the insert. Sanitize once here so the
    # in-memory message, the row, the broadcast, and the next provider
    # request all carry the same text.
    message = Sanitize.message(message)

    case PreFlight.check_passed(state.chat_state.messages, limit) do
      :ok ->
        index = state.chat_state.next_message_index
        stamped = put_message_index(message, index)

        messages = state.chat_state.messages ++ [stamped]

        state = %{
          state
          | chat_state: %{state.chat_state | messages: messages, next_message_index: index + 1}
        }

        AgentPersistence.append_message(
          state.space_id,
          state.name,
          stamped,
          state.chat_state.next_message_index
        )

        Broadcasts.message(state, stamped)

        {:ok, stamped, state}

      {:error, reason} ->
        {:invalid, reason, state}
    end
  end

  defp put_message_index({role, %{index: _} = msg}, index) do
    {role, %{msg | index: index}}
  end

  defp progress_message?({role, _}) when role in [:user, :assistant, :tool], do: true
  defp progress_message?(_), do: false

  defp reset_consecutive(state) do
    %{state | live: %{state.live | machine: %{state.live.machine | loop_count: 0}}}
  end
end
