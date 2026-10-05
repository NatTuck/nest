defmodule Nest.Agents.Agent.Compaction.ResultHandler do
  @moduledoc """
  Handle the compactor's chat-turn result. When the
  ChatTurn finishes successfully it sends
  `{:compaction_done, summary_text, staged, summary_assistant,
  carried_entry}` to the Agent; this module commits the
  compaction:

    1. Strip `think.../think` markers from the summary and
       validate it (empty -> retryable failure).
    2. Re-fetch the vocation from the DB and re-render the
       system prompt + tools. Per AGENTS.md the system
       message may change at compaction (the prefix cache
       is invalidated by the compaction itself).
    3. Persist the staged compaction request (bridge +
       suffix) and the summary assistant — exactly the
       messages that were sent to produce the summary.
    4. Build the fresh system message + the "Summary of
       earlier conversation:" user message; thread the
       carried entry's messages onto the end.
    5. Append the marker via `MessageAppender.append_marker/2`.
    6. Append the post-compaction active list via
       `Agent.__append_messages__/2`.
    7. Broadcast `chat:compaction` and spawn the next chat
       turn.

  Every message gets a message index exactly once, when it
  is committed through the canonical append path. A failed
  compaction persists nothing (the staged request and
  summary are discarded); the only sent-but-not-persisted
  sequence is a failed compaction attempt.

  On failure the compactor's chat turn crashed or returned
  an error: `handle_error/3` flips the agent to
  `:compaction_failed`, broadcasts `chat:error`, and resumes
  the carried entry if any.
  """

  require Logger

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Compaction.Marker
  alias Nest.Agents.Agent.Compaction.Trigger
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.MessageAppender
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.Agent.ToolFilter
  alias Nest.Agents.Agent.Turn
  alias Nest.Agents.Agent.Turn.Idle
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.ThinkTags
  alias Nest.Messages.User
  alias Nest.Tokens.Compactor, as: TokensCompactor
  alias Nest.Tokens.Estimator
  alias Nest.Vocations
  alias Nest.Vocations.Vocation

  @max_consecutive_compactions 3

  # Dispatch entry for `Handlers.handle/2`.
  @spec handle(term(), Agent.t()) :: GenServer.reply()
  def handle({:compaction_done, summary_text, staged, summary_assistant, carried_entry}, state) do
    {:noreply, handle_success(state, summary_text, staged, summary_assistant, carried_entry)}
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

  # Synchronous retry/loop-ack dispatch for
  # `Agent.retry_compaction/1` and `Agent.compaction_loop_detected_ok/1`
  # (both `GenServer.call/3` via `Callbacks.handle_call/3`), so
  # callers wait for the agent to actually handle the request.
  def handle_call(:retry_compaction, _from, state) do
    {:reply, :ok, retry_compaction(state)}
  end

  def handle_call(:compaction_loop_detected_ok, _from, state) do
    {:reply, :ok, loop_detected_ok(state)}
  end

  # Run the success path: re-render system + tools, persist the staged
  # compaction request + summary, append the marker, append the new active
  # segment, broadcast chat:compaction, spawn next. `carried_entry` is nil
  # for Trigger A.
  #
  # Choke point: a missing summary is a hard bug (every marker must be
  # bracketed by the summary it produced). We validate with the shared
  # `Compactor.validate_summary/1` and, on an empty/think-only response,
  # route to the retryable `:compaction_failed` path instead of committing
  # an empty summary.
  @spec handle_success(
          Agent.t(),
          String.t(),
          [tuple()],
          tuple(),
          Agent.Machine.entry() | nil
        ) :: Agent.t()
  def handle_success(state, summary_text, staged, summary_assistant, carried_entry) do
    summary_text = ThinkTags.strip(summary_text)

    case TokensCompactor.validate_summary(summary_text) do
      :ok ->
        commit_success(state, summary_text, staged, summary_assistant, carried_entry)

      {:error, reason} ->
        handle_error(state, reason, carried_entry)
    end
  end

  defp commit_success(state, summary_text, staged, summary_assistant, carried_entry) do
    Logger.info(
      "Compaction complete: agent=#{state.name} from=#{length(state.chat_state.messages)} " <>
        "summary_chars=#{String.length(summary_text)} " <>
        "carried_entry=#{carried_entry_tag(carried_entry)}"
    )

    state =
      state
      |> clear_mid_turn_entry()
      |> put_idle()
      |> reset_crossed_thresholds()
      |> reset_context_projection()
      |> reset_read_files()

    {state, system_prompt} = refresh_vocation_and_tools(state)

    # Persist the staged compaction request (bridge + suffix) and the summary
    # assistant. They land before the marker, so the archived slice is exactly
    # the sequence that was sent to produce the summary. A failed compaction
    # never reaches here, so nothing from it is persisted.
    {:ok, _stamped, state} = Agent.__append_messages__(state, staged ++ [summary_assistant])

    marker_index = state.chat_state.next_message_index
    archived_messages = state.chat_state.messages || []
    archived_count = length(archived_messages)

    {new_messages, marker} =
      build_active_segment(
        state,
        summary_text,
        carried_entry,
        marker_index,
        archived_count,
        system_prompt
      )

    state = archive_active_segment(state, archived_messages)
    state = commit_compaction(state, marker, new_messages)

    Broadcasts.compaction(state, marker)

    spawn_next_chat_turn(state, carried_entry)
  end

  # Re-fetch the vocation from the DB (falling back to the
  # cached `state.vocation` on transient lookup failure via
  # `fetch_fresh_vocation/1`) and re-render the system prompt
  # + tools. Per AGENTS.md, the system message may change at
  # compaction (the prefix cache is invalidated by the
  # compaction itself). Returns the rendered `system_prompt`
  # string so the post-compaction builder can decide whether to
  # prepend it.
  defp refresh_vocation_and_tools(state) do
    fresh_vocation = fetch_fresh_vocation(state)

    {system_prompt, _mode, tool_names, fresh_vocation} =
      SystemPrompt.compose_vocation_config(
        fresh_vocation,
        state.workspace_path,
        {state.llm_metrics.context_limit, state.llm_metrics.context_limit_source},
        state.name,
        state.depth
      )

    tool_names = ToolFilter.exclude_spawn_at_max_depth(tool_names, state.depth)
    tools = Nest.Tools.get_functions(tool_names, state.workspace_path, state.tmp_path)

    {%{state | vocation: fresh_vocation, tools: tools}, system_prompt}
  end

  # Build the post-compaction message sequence: prepended fresh
  # system (when a vocation is present AND the rendered
  # prompt fits the 25% safety budget), summary_user, and
  # the carried entry's messages. Build the marker with
  # token-count stats. Pure — doesn't mutate state.
  defp build_active_segment(
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
      |> Enum.map(&drop_pre_compaction_usage/1)

    tokens_compacted = Estimator.estimate_messages(archived_messages)
    tokens_compacted_to = Estimator.estimate_messages(new_messages)

    marker =
      Marker.build_marker(
        marker_index,
        archived_count,
        state.chat_state.compaction_count + 1,
        tokens_compacted,
        tokens_compacted_to
      )

    {new_messages, marker}
  end

  # Build the post-compaction `{:system, _}` message — only when
  # there's a vocation-derived prompt AND it fits the 25%
  # safety budget. Over-budget prompts are dropped with a
  # warning (the Trigger preflight already refused in that
  # case; this is the in-flight success path).
  defp build_rebuilt_system(system_prompt, context_limit, now) do
    cond do
      is_nil(system_prompt) ->
        nil

      not SystemPrompt.within_size_budget?(system_prompt, context_limit) ->
        Logger.warning(
          "Compaction post-compaction dropping rebuilt system: rendered prompt exceeds " <>
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

  # Place post-compaction entries via the canonical append path: the
  # marker via `append_marker/2` (no broadcast),
  # new messages to `messages` (`__append_messages__/2`).
  defp commit_compaction(state, marker, new_messages) do
    {:ok, _marker, state} = MessageAppender.append_marker(state, marker)
    {:ok, _stamped, state} = Agent.__append_messages__(state, new_messages)
    state
  end

  # Drop the pre-compaction `messages` from memory (their DB rows already
  # exist at their pre-compaction indices; the archive is derived on demand.
  defp archive_active_segment(state, _archived_messages) do
    %{
      state
      | chat_state: %{
          state.chat_state
          | messages: []
        }
    }
  end

  @doc """
  The compactor's chat turn failed. Set `:compaction_failed`
  status, broadcast `chat:error` + `chat:status`. No marker,
  archive, or summary_user (the user sees the real error).
  """
  @spec handle_error(Agent.t(), term(), Agent.Machine.entry() | nil) :: Agent.t()
  def handle_error(state, reason, carried_entry) do
    Logger.warning("Compaction failed: agent=#{state.name} reason=#{inspect(reason)}")

    # The staged compaction request/response are discarded (never persisted);
    # this only flips status and surfaces the error.
    state = put_compaction_failed(state)
    Broadcasts.status(state)

    Broadcasts.compaction_error(
      state,
      "Compaction failed: #{format_reason(reason)}. Click Retry to try again.",
      "Nest.Agents.Agent.Compaction.ResultHandler.handle_error/3"
    )

    cond do
      # A deferred reply is terminal and not part of the failed compaction
      # sequence: leave it in `mid_turn_entry` so Retry re-attempts the
      # compaction, then commits the reply. Do not spawn a turn.
      match?({:assistant_response, _, _, _}, carried_entry) -> state
      carried_entry != nil -> spawn_with_entry(state, carried_entry)
      true -> state
    end
  end

  @doc """
  Mid-turn compaction request from a running ChatTurn.
  """
  @spec needs_entry(Agent.t(), Agent.Machine.entry() | nil) :: Agent.t()
  def needs_entry(state, carried_entry) do
    state = %{
      state
      | live: %{
          state.live
          | machine: %{
              Machine.to_compaction_generating(state.live.machine)
              | mid_turn_entry: %{entry: carried_entry}
            }
        }
    }

    Broadcasts.status(state)
    Trigger.mid_turn(state, carried_entry)
  end

  @spec check_consecutive(Agent.t()) :: :refuse | {:ok, Agent.t()}
  def check_consecutive(state) do
    count = state.live.machine.loop_count + 1

    if count > @max_consecutive_compactions do
      # Report the N compactions that already happened as "attempted".
      set_compaction_loop(
        state,
        :consecutive_compaction_threshold,
        state.live.machine.loop_count,
        @max_consecutive_compactions
      )

      :refuse
    else
      state = %{state | live: %{state.live | machine: %{state.live.machine | loop_count: count}}}
      {:ok, state}
    end
  end

  @spec loop_detected_ok(Agent.t()) :: Agent.t()
  def loop_detected_ok(state) do
    if Machine.status_for(state.live.machine) != :compaction_loop_detected do
      Logger.warning(
        "compaction_loop_detected_ok ignored: agent=#{state.name} " <>
          "status=#{inspect(Machine.status_for(state.live.machine))} (expected :compaction_loop_detected)"
      )

      state
    else
      state = %{
        state
        | live: %{
            state.live
            | machine: %{
                state.live.machine
                | loop_count: 0,
                  pending_user_message: nil
              },
              pending_notice: nil
          }
      }

      Idle.enter(state)
    end
  end

  @spec retry_compaction(Agent.t()) :: Agent.t()
  def retry_compaction(state) do
    cond do
      Machine.status_for(state.live.machine) != :compaction_failed ->
        Logger.warning(
          "retry_compaction ignored: agent=#{state.name} status=#{inspect(Machine.status_for(state.live.machine))} (expected :compaction_failed)"
        )

        state

      entry = state.live.machine.mid_turn_entry ->
        state = clear_mid_turn_entry(state)
        needs_entry(state, entry.entry)

      true ->
        Trigger.post_turn(state)
    end
  end

  # --- private helpers ---

  defp set_compaction_loop(state, reason, attempt_count, max_attempts) do
    state = %{
      state
      | live: %{
          state.live
          | machine: Machine.to_blocked(state.live.machine, :compaction_loop_detected)
        }
    }

    Broadcasts.status(state)

    Broadcasts.compaction_loop(
      state.space_id,
      state.name,
      format_reason(reason),
      inspect(__MODULE__),
      attempt_count,
      max_attempts
    )

    state
  end

  defp clear_mid_turn_entry(state) do
    %{state | live: %{state.live | machine: %{state.live.machine | mid_turn_entry: nil}}}
  end

  defp put_idle(state) do
    %{state | live: %{state.live | machine: Machine.to_idle(state.live.machine)}}
  end

  defp put_compaction_failed(state) do
    %{
      state
      | live: %{state.live | machine: Machine.to_blocked(state.live.machine, :compaction_failed)}
    }
  end

  # Append the carried entry's messages to the post-compaction active
  # list. `:user_message` carries a bare `User.t()` (wrapped here);
  # `:tool_call` and `:compact_tool` already carry wrapped
  # messages.
  defp append_entry_tail(new_messages, {:user_message, msg}),
    do: new_messages ++ [{:user, msg}]

  defp append_entry_tail(new_messages, {:tool_call, msg, _, _}),
    do: new_messages ++ [msg]

  defp append_entry_tail(new_messages, {:compact_tool, [a, b], _, _}),
    do: new_messages ++ [a, b]

  defp append_entry_tail(new_messages, {:assistant_response, msg, _, _}),
    do: new_messages ++ [msg]

  defp append_entry_tail(new_messages, _other), do: new_messages

  # A carried assistant was produced against the pre-compaction context,
  # so its provider-reported `usage` no longer describes the active
  # segment: the summary replaced the messages it measured. Leaving that
  # anchor in place makes `ConversationSize` report the old (large) size
  # and re-trigger compaction immediately. Per `notes/continue.md`, there
  # is no usable anchor after a compaction — the size is estimator-only
  # until the next real reply provides a fresh `usage`. The response's
  # `usage` is still visible in the message's `api_logs`, so dropping the
  # struct field hides nothing.
  defp drop_pre_compaction_usage({:assistant, %Assistant{} = assistant}) do
    {:assistant, %{assistant | usage: nil}}
  end

  defp drop_pre_compaction_usage(message), do: message

  # Look up the freshest vocation from the DB; on nil/error
  # fall back to the cached `state.vocation` (always populated
  # at init, so a nil DB lookup keeps the prompt valid).
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
    state =
      cond do
        # A workspace change deferred its notice via compaction: append the
        # pair and stay idle (no LLM request).
        state.live.pending_notice != nil ->
          ChatPipeline.resume_pending_notice(state)

        # A deferred reply is terminal: it was already appended by the commit
        # (`append_entry_tail/2`), and there is nothing left to ask the LLM.
        match?({:assistant_response, _, _, _}, carried_entry) ->
          put_idle(state)

        carried_entry == nil ->
          ChatPipeline.resume_with_pending(state)

        true ->
          state
          |> put_resumed(carried_entry)
          |> spawn_with_entry(carried_entry)
      end

    # Broadcast the resumed status so the UI leaves the stale
    # `:compacting` and shows the turn that is actually about to run.
    Broadcasts.status(state)
    Idle.drain(state)
  end

  # The machine phase the resumed turn is about to be in. A
  # `{:tool_call, ...}` continuation executes the carried tool calls
  # first (tool phase); a `{:compact_tool, ...}` continuation calls the
  # LLM directly (generating). `resume_with_pending/1` already sets the
  # chat-generating phase; `resume_pending_notice/1` stays idle.
  defp put_resumed(state, {:tool_call, _, _, _}) do
    %{state | live: %{state.live | machine: Machine.to_chat_tools(state.live.machine)}}
  end

  defp put_resumed(state, _entry) do
    %{state | live: %{state.live | machine: Machine.to_chat_generating(state.live.machine)}}
  end

  defp spawn_with_entry(state, entry) do
    {_effective_mode, caps} =
      ChatPipeline.resolve_mode_and_caps(
        state.live.mode,
        state.vocation,
        state.workspace_path,
        state.tmp_path
      )

    Turn.start(state, state.chat_state.messages, entry, caps)
  end

  defp format_reason(:reserve_exhausted),
    do:
      "system prompt + compaction request consume the LLM's full compaction reserve — " <>
        "use a smaller system prompt or change model"

  defp format_reason(:consecutive_compaction_threshold),
    do:
      "compaction isn't reducing the conversation — start a new session, change model, or clear history"

  defp format_reason(:llm_returned_empty), do: "LLM returned empty summary"
  defp format_reason(:timeout), do: "request timed out"
  defp format_reason(:transport_error), do: "transport error"

  defp format_reason({:stream_idle_timeout, ms}) when is_integer(ms),
    do: "no output from the model for #{div(ms, 1_000)}s"

  defp format_reason({:stream_idle_timeout, _ms}), do: "no output from the model"

  defp format_reason({:stream_incomplete, _reason}),
    do: "the response stream ended unexpectedly (connection dropped)"

  defp format_reason({:crash, _kind, _reason}), do: "internal error"
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(_other), do: "internal error"

  defp carried_entry_tag(nil), do: :none
  defp carried_entry_tag({:user_message, _}), do: :user_message
  defp carried_entry_tag({:tool_call, _, _, _}), do: :tool_call
  defp carried_entry_tag({:compact_tool, _, _, _}), do: :compact_tool
  defp carried_entry_tag({:assistant_response, _, _, _}), do: :assistant_response

  # Reset the "already announced" threshold set so the next
  # ChatTurn re-fires warnings if usage rises again after the
  # history was summarized.
  defp reset_crossed_thresholds(state) do
    %{state | live: %{state.live | crossed_thresholds: %MapSet{}}}
  end

  # Drop any in-flight context projection: the pre-compaction message
  # list it measured no longer exists.
  defp reset_context_projection(state) do
    %{state | live: %{state.live | context_projection: nil}}
  end

  # Reset the `read_files` cache. Same pattern as
  # `reset_crossed_thresholds/1` above. See the
  # `ChatState.read_files` moduledoc for why we clear this
  # at compaction-time.
  defp reset_read_files(state) do
    %{state | chat_state: %{state.chat_state | read_files: %{}}}
  end
end
