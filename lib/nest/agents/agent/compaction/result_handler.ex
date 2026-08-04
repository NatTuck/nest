defmodule Nest.Agents.Agent.Compaction.ResultHandler do
  @moduledoc """
  Handle the compactor's chat-turn result. When the
  ChatTurn finishes successfully it sends
  `{:compaction_done, summary_text, carried_entry}` to the
  Agent; this module owns the swap:

    1. Strip `think.../think` markers from the summary.
    2. Re-fetch the vocation from the DB and re-render the
       system prompt + tools. Per AGENTS.md the system
       message may change at compaction (the prefix cache
       is invalidated by the compaction itself).
    3. Build the fresh system message + the "Summary of
       earlier conversation:" user message; thread the
       carried entry's messages onto the end.
    4. Move pre-swap `messages` to `history` (in-memory).
    5. Append the marker to `history` via
       `MessageAppender.append_history_one/2`.
    6. Append the post-swap active list via
       `Agent.__append_messages__/2`.
    7. Broadcast `chat:compaction` and spawn the next chat
       turn.

  Every entry added to `(history ++ messages)` flows through
  the canonical message append path, which always persists
  a row at the assigned index. That makes the invariant
  "if it's in `(history ++ messages)`, it's in the `messages`
  table at its `message_index`" structural — bypasses
  surface as test failures.

  On failure the compactor's chat turn crashed or returned
  an error: `handle_error/3` flips the agent to
  `:compaction_failed`, broadcasts `chat:error`, and resumes
  the carried entry if any.
  """

  require Logger

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.ChatTurnSpawner
  alias Nest.Agents.Agent.Compaction.Marker
  alias Nest.Agents.Agent.Compaction.Trigger
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.ThinkTags
  alias Nest.Messages.User
  alias Nest.Tokens.Estimator
  alias Nest.Vocations
  alias Nest.Vocations.Vocation

  @max_consecutive_compactions 3

  @doc """
  Dispatch entry for `Handlers.handle/2`.
  """
  @spec handle(term(), Agent.t()) :: GenServer.reply()
  def handle({:compaction_done, summary_text, carried_entry}, state) do
    {:noreply, handle_success(state, summary_text, carried_entry)}
  end

  def handle({:compaction_failed, reason, carried_entry}, state) do
    {:noreply, handle_error(state, reason, carried_entry)}
  end

  def handle({:needs_compaction, _chat_turn_pid, carried_entry}, state) do
    {:noreply, needs_entry(state, carried_entry)}
  end

  def handle(:retry_compaction, state) do
    {:noreply, retry_compaction(state)}
  end

  def handle(:compaction_loop_detected_ok, state) do
    {:noreply, loop_detected_ok(state)}
  end

  # Synchronous retry/loop-ack dispatch for `Agent.retry_compaction/1`
  # and `Agent.compaction_loop_detected_ok/1` (both `GenServer.call/3`,
  # via `Nest.Agents.Agent.Callbacks.handle_call/3`). Replaces the
  # previous `send/2` paths so callers wait for the agent to actually
  # handle the request — the channel's `:reply, :ok, socket` only
  # makes sense after the agent has run. Tests no longer need a drain.
  def handle_call(:retry_compaction, _from, state) do
    {:reply, :ok, retry_compaction(state)}
  end

  def handle_call(:compaction_loop_detected_ok, _from, state) do
    {:reply, :ok, loop_detected_ok(state)}
  end

  @doc """
  Run the success path: re-render system + tools, archive
  pre-swap, append marker to history, append new active
  messages, broadcast chat:compaction, spawn next.

  `summary_text` is the raw LLM text (may contain
  `think.../think` markers). `carried_entry` is the third
  element of the compactor entry — `nil` for Trigger A
  (post-turn) or the carried `{:tool_call, _, _, _}` /
  `{:compact_tool, _, _, _}` for Trigger B (mid-turn).
  """
  @spec handle_success(Agent.t(), String.t(), Agent.ChatTurn.State.entry() | nil) :: Agent.t()
  def handle_success(state, summary_text, carried_entry) do
    Logger.info(
      "Compaction complete: agent=#{state.name} from=#{length(state.chat_state.messages)} " <>
        "summary_chars=#{String.length(summary_text)} " <>
        "carried_entry=#{carried_entry_tag(carried_entry)}"
    )

    state =
      state
      |> clear_mid_turn_entry()
      |> put_status(:idle)
      |> reset_crossed_thresholds()
      |> reset_read_files()

    {state, system_prompt} = refresh_vocation_and_tools(state)
    summary_text = ThinkTags.strip(summary_text)

    marker_index = state.chat_state.next_message_index
    archived_messages = state.chat_state.messages || []
    archived_count = length(archived_messages)

    {new_messages, marker} =
      build_post_swap_messages(
        state,
        summary_text,
        carried_entry,
        marker_index,
        archived_count,
        system_prompt
      )

    state = archive_pre_swap(state, archived_messages)
    state = apply_post_swap(state, marker, new_messages)

    Broadcasts.compaction(state.name, marker, state.chat_state.history)

    spawn_next_chat_turn(state, carried_entry)
  end

  # Re-fetch the vocation from the DB (falling back to the
  # cached `state.vocation` on transient lookup failure via
  # `fetch_fresh_vocation/1`) and re-render the system prompt
  # + tools. Per AGENTS.md, the system message may change at
  # compaction (the prefix cache is invalidated by the
  # compaction itself). Returns the rendered `system_prompt`
  # string so the post-swap builder can decide whether to
  # prepend it.
  defp refresh_vocation_and_tools(state) do
    fresh_vocation = fetch_fresh_vocation(state)

    {system_prompt, _mode, tool_names, fresh_vocation} =
      SystemPrompt.compose_vocation_config(
        fresh_vocation,
        state.workspace_path,
        {state.llm_metrics.context_limit, state.llm_metrics.context_limit_source},
        state.depth
      )

    tools = Nest.Tools.get_functions(tool_names, state.workspace_path, state.tmp_path)

    {%{state | vocation: fresh_vocation, tools: tools}, system_prompt}
  end

  # Build the post-swap message sequence: prepended fresh
  # system (when a vocation is present AND the rendered
  # prompt fits the 25% safety budget), summary_user, and
  # the carried entry's messages. Build the marker with
  # token-count stats. Pure — doesn't mutate state.
  defp build_post_swap_messages(
         state,
         summary_text,
         carried_entry,
         marker_index,
         archived_count,
         system_prompt
       ) do
    now = DateTime.utc_now()
    archived_messages = state.chat_state.messages || []

    summary_user =
      {:user,
       %User{
         parts: [%Part.Text{text: "Summary of earlier conversation:\n\n" <> summary_text}],
         timestamp: now,
         api_logs: []
       }}

    rebuilt_system = build_rebuilt_system(system_prompt, state.llm_metrics.context_limit, now)

    new_messages =
      case rebuilt_system do
        nil -> append_entry_tail([summary_user], carried_entry)
        sys -> [sys | append_entry_tail([summary_user], carried_entry)]
      end

    tokens_compacted = Estimator.estimate_messages(archived_messages)
    tokens_compacted_to = Estimator.estimate_messages(new_messages)

    marker =
      Marker.build_marker(marker_index, archived_count, tokens_compacted, tokens_compacted_to)

    {new_messages, marker}
  end

  # Build the post-swap `{:system, _}` message — only when
  # we have a vocation-derived prompt AND it fits within the
  # 25% safety budget. Over-budget prompts are NOT produced
  # (the Trigger's preflight already refused the compaction
  # in that case; this is the in-flight success path, where
  # the system had a chance to grow between Trigger's render
  # and ours — we drop it and log a warning so the next
  # message-flow can surface a clearer error).
  defp build_rebuilt_system(system_prompt, context_limit, now) do
    cond do
      is_nil(system_prompt) ->
        nil

      not SystemPrompt.within_size_budget?(system_prompt, context_limit) ->
        Logger.warning(
          "Compaction post-swap dropping rebuilt system: rendered prompt exceeds " <>
            "25% safety budget for context_limit=#{context_limit}"
        )

        nil

      true ->
        {:system,
         %System{
           parts: [%Part.Text{text: system_prompt}],
           timestamp: now,
           api_logs: [],
           metadata: nil,
           tokens: nil
         }}
    end
  end

  # Place post-swap entries via the canonical message append
  # path. The marker goes to `history` via `append_history_one/2`
  # (no `chat:message` broadcast). New messages go to `messages`
  # via `__append_messages__/2` (with `chat:message` broadcast).
  defp apply_post_swap(state, marker, new_messages) do
    {_marker, state} = MessageAppender.append_history_one(state, marker)
    {_stamped, state} = Agent.__append_messages__(state, new_messages)
    state
  end

  # Move pre-swap `messages` to `history` (in-memory only;
  # their DB rows already exist at their pre-swap indices).
  defp archive_pre_swap(state, archived_messages) do
    %{
      state
      | chat_state: %{
          state.chat_state
          | messages: [],
            history: (state.chat_state.history || []) ++ archived_messages
        }
    }
  end

  @doc """
  The compactor's chat turn failed. Set
  `:compaction_failed` status, broadcast `chat:error` +
  `chat:status`. No marker, no archive, no summary_user
  (the user sees the real LLM error response if any).
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

    if carried_entry do
      spawn_with_entry(state, carried_entry)
    else
      state
    end
  end

  @doc """
  Mid-turn compaction request from a running ChatTurn.
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
    Trigger.mid_turn(state, carried_entry)
  end

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

  @spec retry_compaction(Agent.t()) :: Agent.t()
  def retry_compaction(state) do
    cond do
      state.chat_state.status != :compaction_failed ->
        Logger.warning(
          "retry_compaction ignored: agent=#{state.name} status=#{inspect(state.chat_state.status)} (expected :compaction_failed)"
        )

        state

      entry = state.chat_state.mid_turn_entry ->
        state = clear_mid_turn_entry(state)
        needs_entry(state, entry.entry)

      true ->
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

  # Append the carried entry's messages to the post-swap active
  # list. `:user_message` carries a bare `User.t()` (wrapped here);
  # `:tool_call` and `:compact_tool` already carry wrapped
  # messages.
  defp append_entry_tail(new_messages, {:user_message, msg}),
    do: new_messages ++ [{:user, msg}]

  defp append_entry_tail(new_messages, {:tool_call, msg, _, _}),
    do: new_messages ++ [msg]

  defp append_entry_tail(new_messages, {:compact_tool, [a, b], _, _}),
    do: new_messages ++ [a, b]

  defp append_entry_tail(new_messages, _other), do: new_messages

  # Look up the freshest vocation from the DB. On nil or
  # transient error, fall back to the cached `state.vocation`.
  # In production `state.vocation` is always populated (set at
  # agent init from the DB), so a nil-on-DB-lookup return still
  # has a cached value to use; the system prompt stays valid
  # even if a parallel writer deleted the vocation row.
  #
  # `DBConnection.OwnershipError` fires when this GenServer
  # runs inside an async test where the Ecto sandbox ownership
  # is held by the test process, not the Agent. In production
  # the global pool doesn't sandbox, so this rescue is a no-op
  # there. Real DB exceptions are logged so we don't silently
  # paper over outages.
  defp fetch_fresh_vocation(state) do
    case Vocations.get_vocation(state.vocation_id) do
      %Vocation{} = v ->
        v

      nil ->
        state.vocation
    end
  rescue
    _ in [DBConnection.OwnershipError] ->
      state.vocation

    error ->
      Logger.warning(
        "Vocation lookup failed during compaction: #{inspect(error)}. " <>
          "Using cached state. agent=#{state.name}"
      )

      state.vocation
  end

  defp spawn_next_chat_turn(state, carried_entry) do
    case carried_entry do
      nil -> ChatPipeline.resume_with_pending(state)
      entry -> spawn_with_entry(state, entry)
    end
  end

  defp spawn_with_entry(state, entry) do
    {_effective_mode, caps} =
      ChatPipeline.resolve_mode_and_caps(state.mode, state.vocation)

    ChatTurnSpawner.spawn(state, state.chat_state.messages, entry, caps)
  end

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

  defp carried_entry_tag(nil), do: :none
  defp carried_entry_tag({:user_message, _}), do: :user_message
  defp carried_entry_tag({:tool_call, _, _, _}), do: :tool_call
  defp carried_entry_tag({:compact_tool, _, _, _}), do: :compact_tool

  # Reset the "already announced" threshold set so the next
  # ChatTurn re-fires warnings if usage rises again after the
  # history was summarized.
  defp reset_crossed_thresholds(state) do
    %{state | chat_state: %{state.chat_state | crossed_thresholds: %MapSet{}}}
  end

  # Reset the `read_files` cache. Same pattern as
  # `reset_crossed_thresholds/1` above. See the
  # `ChatState.read_files` moduledoc for why we clear this
  # at compaction-time.
  defp reset_read_files(state) do
    %{state | chat_state: %{state.chat_state | read_files: %{}}}
  end
end
