defmodule Nest.Agents.Agent.Compaction.ResultHandler do
  @moduledoc """
  Handle the result of the compactor's chat turn. The
  compactor is a new chat turn (entry
  `{:compaction, _, _}`); when it finishes, the ChatTurn
  sends `{:compaction_done, summary_text, carried_entry}` to
  the Agent. This module owns the post-turn work:

    1. Strip `<think>...</think>` content from `summary_text`.
    2. Build the post-compaction "Summary of earlier
       conversation:" user message (`summary_user`).
    3. Append `summary_user` via `__append_message__/2`
       (broadcasts `chat:message`).
    4. Build the compaction marker + archive the
       pre-summary_user messages from `messages` to `history`
       (same as the current `Compaction.Lifecycle.apply/2`).
    5. Update `last_compaction_index`, persist the marker,
       broadcast `chat:compaction`.
    6. Spawn the next chat turn with `carried_entry` (or
       resume the held user message if `carried_entry` is
       `nil` and `pending_user_message` is set).

  On failure (the compactor's chat turn crashed / the
  LLM call returned an error), the Agent enters
  `:compaction_failed` and broadcasts `chat:error`. No
  message is synthesized — the real LLM error response is
  what the user sees in the chat (if any).

  The `append_continuation_tail/2` helper threads the
  carried messages (from `carried_entry`) onto the
  post-swap active list. `:user_message` carries a bare
  `User.t()` (wrapped here); `:tool_call` and
  `:compact_tool` already carry wrapped messages.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.ChatTurnSpawner
  alias Nest.Agents.Agent.Compaction.Marker
  alias Nest.Agents.Agent.Compaction.Trigger
  alias Nest.Messages.Part
  alias Nest.Messages.ThinkTags
  alias Nest.Messages.User
  alias Nest.Tokens.Estimator

  @max_consecutive_compactions 3

  @doc """
  The compactor's chat turn finished. Run the success path:
  strip → summary_user → append → archive → persist →
  broadcast → spawn next.

  `summary_text` is the raw LLM text (may contain
  `<think>...</think>` markers). `carried_entry` is the
  third element of the compactor entry — `nil` for
  Trigger A (post-turn) or the carried `{:tool_call, _,
  _, _}` / `{:compact_tool, _, _, _}` for Trigger B
  (mid-turn). The next chat turn is spawned with
  `carried_entry` if non-nil, or with the held user
  message if `carried_entry` is `nil`.
  """
  @spec handle_success(Agent.t(), String.t(), Agent.ChatTurn.State.entry() | nil) :: Agent.t()
  def handle_success(state, summary_text, carried_entry) do
    Logger.info(
      "Compaction complete: agent=#{state.name} from=#{length(state.chat_state.messages)} " <>
        "summary_chars=#{String.length(summary_text)} " <>
        "carried_entry=#{carried_entry_tag(carried_entry)}"
    )

    state = clear_mid_turn_entry(state)
    state = put_status(state, :idle)

    # 1. Strip `<think>...</think>` content from the
    #    summary text. Stripped once here (when building
    #    summary_user); the assistant row carries the raw
    #    text (any `<think>` markers are visible in the
    #    JS history pane via `splitThinkFromParts`).
    summary_text = ThinkTags.strip(summary_text)

    # 2. Capture the messages that will be archived
    #    (pre-swap), build the marker, and update the
    #    state in one atomic swap. The summary_user is
    #    built and assigned indices in the post-swap
    #    active list (NOT pre-appended to the pre-swap
    #    messages).
    marker_index = state.chat_state.next_message_index
    archived_messages = state.chat_state.messages || []
    archived_count = length(archived_messages)

    now = DateTime.utc_now()

    summary_user =
      {:user,
       %User{
         parts: [
           %Part.Text{
             text: "Summary of earlier conversation:\n\n" <> summary_text
           }
         ],
         timestamp: now,
         api_logs: []
       }}

    # 3. The new active list is [summary_user] ++
    #    carried_messages (the carried entry's messages).
    new_messages = append_entry_tail([summary_user], carried_entry)
    new_messages = assign_indices(new_messages, marker_index + 1)

    # 4. Build the marker (token counts available now).
    tokens_compacted = Estimator.estimate_messages(archived_messages)
    tokens_compacted_to = Estimator.estimate_messages(new_messages)

    marker =
      Marker.build_marker(marker_index, archived_count, tokens_compacted, tokens_compacted_to)

    # 5. Swap: move pre-swap messages to history (with
    #    the marker), replace active list with
    #    new_messages, bump next_message_index and
    #    last_compaction_index.
    state = Marker.swap_messages(state, new_messages, marker_index, marker)

    # 6. Persist compaction (DB writes) + broadcast
    #    chat:compaction.
    state =
      Marker.persist_and_broadcast(
        state,
        marker_index,
        marker,
        archived_count,
        tokens_compacted,
        tokens_compacted_to
      )

    # 7. Spawn the next chat turn. `carried_entry` is
    #    non-nil for mid-turn resumption (Trigger B). For
    #    post-turn (Trigger A), resume the held user
    #    message via `ChatPipeline.resume_with_pending/1`.
    state = spawn_next_chat_turn(state, carried_entry)
    state
  end

  @doc """
  The compactor's chat turn failed. Set
  `:compaction_failed` status, broadcast `chat:error` +
  `chat:status`. No marker, no archive, no summary_user
  (the user sees the real LLM error response in the chat
  if the LLM produced one, plus the banner).

  If `carried_entry` is non-nil, the next chat turn is
  spawned with it (the tool call sequence resumes —
  skipping the compaction). If `carried_entry` is `nil`,
  the held user message stays in `pending_user_message`
  for a retry.
  """
  @spec handle_error(Agent.t(), term(), Agent.ChatTurn.State.entry() | nil) :: Agent.t()
  def handle_error(state, reason, carried_entry) do
    Logger.warning("Compaction failed: agent=#{state.name} reason=#{inspect(reason)}")

    state = put_status(state, :compaction_failed)
    Broadcasts.status(state.name, state)

    Broadcasts.compaction_error(
      state.name,
      "Compaction failed: #{format_reason(reason)}. Click Retry to try again.",
      "Nest.Agents.Agent.Compaction.ResultHandler.handle_error/3"
    )

    # Spawn the next chat turn with the carried entry
    # (if any) so the tool call sequence resumes despite
    # the compaction failure. Post-turn failures leave
    # the held user message in `pending_user_message` for
    # a retry.
    if carried_entry do
      spawn_with_entry(state, carried_entry)
    else
      state
    end
  end

  @doc """
  Mid-turn compaction request from a running ChatTurn.
  The ChatTurn detected (a) projected tool results
  would push past `context_limit - reserve` and emitted
  its tool calls via the `:tool_call` entry, OR (b) the
  LLM emitted `context.compact` and the chat turn exited
  with the `:compact_tool` entry. Both paths get here —
  the entry shape carries the resume payload.

  Sets `:compacting` status, broadcasts it, runs the
  loop-breaker check, then starts the compactor's chat
  turn. On success the compactor's chat turn runs
  normally; on failure `handle_error/3` is called.
  """
  @spec needs_entry(Agent.t(), Agent.ChatTurn.State.entry() | nil) :: Agent.t()
  def needs_entry(state, carried_entry) do
    state = %{
      state
      | chat_state: %{
          state.chat_state
          | status: :compacting,
            mid_turn_entry: %{entry: carried_entry}
        }
    }

    Broadcasts.status(state.name, state)

    # Delegate to the trigger module. The trigger runs
    # the loop-breaker check (via `check_consecutive/1`)
    # and spawns the compactor's chat turn.
    Trigger.mid_turn(state, carried_entry)
  end

  @doc """
  Check whether another compaction should be allowed.
  Increments `consecutive_compaction_count`; when the
  count exceeds the threshold, transitions the agent to
  `:compaction_loop_detected`, broadcasts
  `chat:compaction-loop`, and refuses the spawn.
  Returns `:refuse` (the spawn should not happen — caller
  should noop) or `{:ok, state}` with the bumped
  counter (caller proceeds normally).
  """
  @spec check_consecutive(Agent.t()) :: :refuse | {:ok, Agent.t()}
  def check_consecutive(state) do
    count = state.chat_state.consecutive_compaction_count + 1

    if count > @max_consecutive_compactions do
      set_compaction_loop(state, :consecutive_compaction_threshold)
      :refuse
    else
      state = %{state | chat_state: %{state.chat_state | consecutive_compaction_count: count}}
      {:ok, state}
    end
  end

  @doc """
  User clicked the OK button on the loop banner. Restore
  `:idle` so new `chat:message` traffic resumes; reset the
  counter to give the next compaction a fresh budget;
  clear any held user message (the OK is an explicit
  acknowledgment, not an implicit retry of the held
  message — the user types new).
  """
  @spec loop_detected_ok(Agent.t()) :: Agent.t()
  def loop_detected_ok(state) do
    if state.chat_state.status != :compaction_loop_detected do
      Logger.warning(
        "compaction_loop_detected_ok ignored: agent=#{state.name} " <>
          "status=#{inspect(state.chat_state.status)} (expected :compaction_loop_detected)"
      )

      state
    else
      state = %{
        state
        | chat_state: %{
            state.chat_state
            | status: :idle,
              consecutive_compaction_count: 0,
              pending_user_message: nil
          }
      }

      Broadcasts.status(state.name, state)
      state
    end
  end

  @doc """
  User clicked the retry button on a `:compaction_failed`
  banner. Re-runs the compactor. Branches on whether the
  failed compaction was mid-turn (carried entry is set in
  `mid_turn_entry`) or post-turn (held user message in
  `pending_user_message`).

  Guard: only valid when the agent is in
  `:compaction_failed` status. If the agent is in any
  other state, no-op (the retry is meaningless outside
  of a failed-compaction context).
  """
  @spec retry_compaction(Agent.t()) :: Agent.t()
  def retry_compaction(state) do
    cond do
      state.chat_state.status != :compaction_failed ->
        Logger.warning(
          "retry_compaction ignored: agent=#{state.name} status=#{inspect(state.chat_state.status)} (expected :compaction_failed)"
        )

        state

      entry = state.chat_state.mid_turn_entry ->
        # Mid-turn retry: re-spawn the compactor with
        # the preserved entry. The `needs_entry/2`
        # function runs the loop-breaker again.
        state = clear_mid_turn_entry(state)
        needs_entry(state, entry.entry)

      true ->
        # Post-turn retry: the held user message is in
        # `pending_user_message`. Re-run the post-turn
        # trigger; on success, `handle_success/3` resumes
        # with the held message.
        Trigger.post_turn(state)
    end
  end

  # --- private helpers ---

  defp set_compaction_loop(state, reason) do
    state = %{state | chat_state: %{state.chat_state | status: :compaction_loop_detected}}
    Broadcasts.status(state.name, state)
    Broadcasts.compaction_loop(state.name, format_reason(reason), inspect(__MODULE__))
    state
  end

  defp clear_mid_turn_entry(state) do
    %{state | chat_state: %{state.chat_state | mid_turn_entry: nil}}
  end

  defp put_status(state, status) do
    %{state | chat_state: %{state.chat_state | status: status}}
  end

  # Append the carried entry's messages to the
  # post-swap active list. `:user_message` carries a
  # bare `User.t()` (no role wrapper); wrap here to
  # match the rest of the messages list. `:tool_call`
  # and `:compact_tool` already carry wrapped messages.
  defp append_entry_tail(new_messages, {:user_message, msg}) do
    new_messages ++ [{:user, msg}]
  end

  defp append_entry_tail(new_messages, {:tool_call, msg, _, _}) do
    new_messages ++ [msg]
  end

  defp append_entry_tail(new_messages, {:compact_tool, [tool_call_msg, tool_result_msg], _, _}) do
    new_messages ++ [tool_call_msg, tool_result_msg]
  end

  defp append_entry_tail(new_messages, _other) do
    # `:compaction` and other entries are not carried
    # in the entry tail (they're not continuations).
    new_messages
  end

  # Assign monotonically-increasing message indices
  # starting at `start_index`. Pure utility.
  defp assign_indices(messages, start_index) do
    {messages, _} =
      Enum.map_reduce(messages, start_index, fn msg, idx ->
        {assign_index(msg, idx), idx + 1}
      end)

    messages
  end

  defp assign_index({role, %{index: _} = struct}, idx) do
    {role, %{struct | index: idx}}
  end

  defp assign_index(other, _idx), do: other

  # The marker construction + state swap + DB write +
  # broadcast live in `Nest.Agents.Agent.Compaction.Marker`
  # (extracted to keep this module under credo's 500-line
  # cap).

  # Spawn the next chat turn. For Trigger B (mid-turn
  # resume), `carried_entry` is non-nil and we spawn
  # with it directly. For Trigger A (post-turn), the
  # held user message is in `pending_user_message`;
  # `ChatPipeline.resume_with_pending/1` appends it
  # and spawns a normal `{:user_message, _}` entry.
  defp spawn_next_chat_turn(state, carried_entry) do
    case carried_entry do
      nil ->
        ChatPipeline.resume_with_pending(state)

      entry ->
        spawn_with_entry(state, entry)
    end
  end

  defp spawn_with_entry(state, entry) do
    {_effective_mode, caps} =
      ChatPipeline.resolve_mode_and_caps(state.mode, state.vocation)

    ChatTurnSpawner.spawn(state, state.chat_state.messages, entry, caps)
  end

  # Start the compactor's chat turn. Builds the
  # `[mode: compact]` suffix, appends it to the
  # messages list (so the user sees the request in
  # the chat), then spawns a ChatTurn with
  # `{:compaction, suffix, carried_entry}` entry.
  #
  # If the system message is missing or the budget
  # computation fails, the trigger module broadcasts
  # `chat:error` and the agent stays in the current
  # state (no spawn).

  # Render the compaction failure reason as a
  # user-facing string.
  defp format_reason(:reserve_exhausted),
    do:
      "system prompt + compaction request consume the LLM's full response budget — " <>
        "use a smaller system prompt or change model"

  defp format_reason(:consecutive_compaction_threshold),
    do:
      "compaction isn't reducing the conversation — start a new session, change model, or clear history"

  defp format_reason(:llm_returned_empty), do: "LLM returned empty summary"
  defp format_reason(:timeout), do: "request timed out"
  defp format_reason(:transport_error), do: "transport error"
  defp format_reason({:crash, _kind, _reason}), do: "internal error"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(_other), do: "internal error"

  # Debug-friendly tag for the log line.
  defp carried_entry_tag(nil), do: :none
  defp carried_entry_tag({:user_message, _}), do: :user_message
  defp carried_entry_tag({:tool_call, _, _, _}), do: :tool_call
  defp carried_entry_tag({:compact_tool, _, _, _}), do: :compact_tool
end
