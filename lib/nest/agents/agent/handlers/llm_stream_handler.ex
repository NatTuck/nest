defmodule Nest.Agents.Agent.Handlers.LLMStreamHandler do
  @moduledoc """
  `handle_info/2` handlers for LLM streaming events:
  `{:delta_received, _}`, `{:thinking_signature_received, _}`,
  `{:llm_error, _}`, `{:tool_calls_received, _}`,
  `{:tool_results_received, _}`, `{:llm_usage, _}`.

  `{:llm_error, _}` is the HTTP worker's "I gave up; please
  finalize and broadcast" signal. The Agent is the single
  source of `chat:error` events — the worker doesn't broadcast
  directly (avoids duplicate events).

  `{:delta_received, _}` and `{:thinking_signature_received, _}`
  update `state.chat_state.streaming_acc` (the authoritative
  in-flight accumulator) and broadcast `chat:delta` from here.
  Broadcasting from the Agent — not the HTTP worker — guarantees
  the test/UI sees the broadcast only after the accumulator is
  updated, so `assert_receive {:chat_delta, _}` is a reliable
  sync point for the accumulator's state.

  `{:tool_calls_received, _}` and `{:tool_results_received, _}`
  pair the message-append with the status transition
  (`:streaming → :executing_tools → :streaming`) and seed a
  fresh `streaming_acc` for the next iteration's response.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Streaming
  alias Nest.Messages.Tool

  require Logger

  @doc """
  Dispatch a streaming message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:delta_received, content, part_type}, state) do
    delta_received(content, part_type, state)
  end

  def handle({:thinking_signature_received, sig}, state) do
    thinking_signature_received(sig, state)
  end

  def handle({:llm_error, error_msg}, state) do
    llm_error(error_msg, state)
  end

  def handle({:tool_calls_received, {:assistant, %Assistant{} = msg}}, state) do
    tool_calls_received(msg, state)
  end

  def handle({:tool_results_received, {:tool, %Tool{} = msg}}, state) do
    tool_results_received(msg, state)
  end

  def handle({:llm_usage, usage}, state) do
    llm_usage(usage, state)
  end

  # The ChatTurn's lifecycle signals (`{:chat_idle, _}`,
  # `{:chat_stopped, _}`, `{:chat_crashed, _, _}`) are
  # routed to `ChatTurnHandler` by the top-level
  # `Handlers` dispatcher. This module keeps the legacy
  # `chat_task_crashed` path for backward compat.

  # Accumulate delta using Streaming module based on content type.
  # If the streaming_acc is nil (e.g. a late delta from a
  # previous chat arrived after `chat_stopped` cleared it,
  # or between two chats before `prepare_streaming_state`
  # ran), no-op. The next chat's `prepare_streaming_state`
  # will re-init the accumulator; any later deltas will find
  # it set.
  #
  # Broadcasts `chat:delta` from here (not from the HTTP
  # worker) so subscribers only see the event after the
  # accumulator is updated. This eliminates the race where
  # a test receives `chat:delta` and then `Agent.stop_chat`
  # fires before the agent has processed the corresponding
  # `{:delta_received, _}` — leaving `streaming_acc` nil when
  # the `chat_stopped` handler tries to finalize the partial.
  defp delta_received(delta_content, :text, state) do
    acc = state.chat_state.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      chars_start = acc.chars_sent
      new_acc = Streaming.append_text(acc, delta_content)
      Broadcasts.delta_text(state.name, new_acc.index, delta_content, chars_start)
      {:noreply, %{state | chat_state: %{state.chat_state | streaming_acc: new_acc}}}
    end
  end

  defp delta_received(delta_content, :thinking, state) do
    acc = state.chat_state.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      # `chars_sent` tracks text + thinking combined (see
      # `Streaming.append_thinking/3`), so the same
      # `acc.chars_sent` works as `chars_start` for both
      # text and thinking deltas.
      chars_start = acc.chars_sent
      new_acc = Streaming.append_thinking(acc, delta_content)
      Broadcasts.delta_thinking(state.name, new_acc.index, delta_content, chars_start)
      {:noreply, %{state | chat_state: %{state.chat_state | streaming_acc: new_acc}}}
    end
  end

  defp delta_received(delta_content, _part_type, state) do
    # For unsupported types, append as text for now.
    delta_received(delta_content, :text, state)
  end

  # Anthropic's extended thinking emits a signature alongside the
  # thinking content. Stash it on the streaming accumulator so it
  # round-trips into the persisted assistant message's metadata.
  defp thinking_signature_received(signature, state) do
    new_acc = %{state.chat_state.streaming_acc | thinking_signature: signature}
    {:noreply, %{state | chat_state: %{state.chat_state | streaming_acc: new_acc}}}
  end

  # Finalize error message. The HTTP worker sent us the
  # formatted error string; we are the single source of
  # `chat:error` events (the worker no longer broadcasts
  # directly — that double-broadcast was a bug). The error
  # is broadcast with the `[Source: ChatTurn.run_chat_task/1]`
  # tag so the user can grep the server log for the matching
  # entry.
  defp llm_error(error_msg, state) do
    _ = state.chat_state.streaming_acc && state.chat_state.streaming_acc.index

    error_message =
      {:assistant,
       %Assistant{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [%Part.Text{text: error_msg}],
         api_logs: triggering_message_api_logs(state)
       }}

    {stamped, state} = Nest.Agents.Agent.__append_message__(state, error_message)
    stamped_index = Nest.Agents.Agent.stamped_index(stamped)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | streaming_acc: nil,
            active_message_index: stamped_index,
            pending_api_logs:
              Nest.Agents.Agent.__clear_pending_api_logs__(state, stamped_index).chat_state.pending_api_logs,
            status: :idle
        }
    }

    Broadcasts.error(state.name, stamped_index, error_msg, "ChatTurn.run_chat_task/1")
    Broadcasts.status(state.name, state)
    {:noreply, state}
  end

  # Build the user-facing error message. We lead with the
  # exception's message (the part the user is most likely to
  # recognize — e.g. "protocol Enumerable not implemented for
  # Atom. ... Got value: nil") and then append a 5-frame
  # stacktrace snippet so the UI shows where the crash
  # happened. The full stacktrace is in the server log
  # (logged by both the chat task and this handler).
  # The pending api_logs lookup uses the Agent's
  # `next_message_index` (the value the ChatTurn queried
  # at the start of the iteration) rather than the
  # message's `index` field. The ChatTurn builds the
  # assistant/tool message with `index: nil` and queues
  # the request api_log at `active_message_index` (which
  # equals `next_message_index` at the time of the
  # request). When the Agent stamps the message via
  # `__append_message__/2`, the message's `index` IS the
  # same number, but the lookup happens BEFORE the stamp
  # — so we use `next_message_index` (the pre-stamp value).
  defp tool_calls_received(tool_call_message, state) do
    pending_logs =
      Nest.Agents.Agent.__pending_api_logs__(state, state.chat_state.next_message_index)

    tool_call_message =
      if pending_logs != [] do
        {:assistant,
         %{
           tool_call_message
           | api_logs: (tool_call_message.api_logs || []) ++ pending_logs,
             index: nil
         }}
      else
        {:assistant, %{tool_call_message | index: nil}}
      end

    {stamped, state} = Nest.Agents.Agent.__append_message__(state, tool_call_message)
    stamped_index = Nest.Agents.Agent.stamped_index(stamped)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | pending_api_logs:
              Nest.Agents.Agent.__clear_pending_api_logs__(state, stamped_index).chat_state.pending_api_logs,
            status: :executing_tools
        }
    }

    Broadcasts.status(state.name, state)
    {:noreply, state}
  end

  defp tool_results_received(tool_result_message, state) do
    pending_logs =
      Nest.Agents.Agent.__pending_api_logs__(state, state.chat_state.next_message_index)

    tool_result_message =
      if pending_logs != [] do
        {:tool,
         %{
           tool_result_message
           | api_logs: (tool_result_message.api_logs || []) ++ pending_logs,
             index: nil
         }}
      else
        {:tool, %{tool_result_message | index: nil}}
      end

    {stamped, state} = Nest.Agents.Agent.__append_message__(state, tool_result_message)
    stamped_index = Nest.Agents.Agent.stamped_index(stamped)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | pending_api_logs:
              Nest.Agents.Agent.__clear_pending_api_logs__(state, stamped_index).chat_state.pending_api_logs,
            status: :streaming,
            streaming_acc: Streaming.new(stamped_index + 1)
        }
    }

    Broadcasts.status(state.name, state)
    {:noreply, state}
  end

  defp llm_usage(usage, state) do
    # Mark the last message in the Agent's messages list with
    # the API-reported total tokens for this LLM call. This
    # happens BEFORE the assistant message is appended (the
    # `:tool_calls_received` handler is sequenced after `:llm_usage`
    # in the Agent's mailbox), so the last message in the list
    # IS the last message the LLM saw in its input. Future
    # `ConversationSize.size/1` calls will use this as the floor.
    state = mark_last_message_tokens(state, usage)

    # Merge per-call usage into the running totals and broadcast a
    # fresh `chat:status` so the chip can update mid-stream.
    # `last_input` is overwritten (not summed): each LLM call's
    # `prompt_tokens` is the size of the full context sent for that
    # call, so the *most recent* value is the current context size.
    # `total_output` and `total_reasoning` are cumulative across the
    # session.
    state = %{
      state
      | llm_metrics: %{
          state.llm_metrics
          | usage_totals: Broadcasts.merge_usage_totals(state.llm_metrics.usage_totals, usage)
        }
    }

    Broadcasts.status(state.name, state)
    {:noreply, state}
  end

  # Mark the last message in `state.chat_state.messages` with
  # the API-reported total tokens (input + cache_read +
  # cache_creation). No-op when `usage` lacks `input_tokens` or
  # the messages list is empty (defensive — shouldn't happen in
  # practice but keeps the handler robust).
  @spec mark_last_message_tokens(Nest.Agents.Agent.t(), map() | nil) ::
          Nest.Agents.Agent.t()
  defp mark_last_message_tokens(state, %{input_tokens: n} = usage)
       when is_integer(n) and n > 0 do
    total =
      n + Map.get(usage, :cache_read_input_tokens, 0) +
        Map.get(usage, :cache_creation_input_tokens, 0)

    messages = state.chat_state.messages

    case List.last(messages) do
      nil ->
        state

      {role, msg} ->
        # Update the last tuple in place: replace the inner
        # struct with a copy that has `:tokens` set. We use
        # `List.update_at/3` directly because `put_in` with
        # `Access.elem/1` traverses through the inner struct
        # and requires the Access behaviour, which the message
        # structs don't auto-derive for this nested case.
        updated_last = {role, %{msg | tokens: total}}
        new_messages = List.replace_at(messages, length(messages) - 1, updated_last)
        %{state | chat_state: %{state.chat_state | messages: new_messages}}
    end
  end

  defp mark_last_message_tokens(state, _usage), do: state

  # The ChatTurn's lifecycle signals (`{:chat_idle, _}`,
  # `{:chat_stopped, _}`, `{:chat_crashed, _, _}`) are
  # routed to `ChatTurnHandler` by the top-level
  # `Handlers` dispatcher.

  # The api_log handler broadcasts the request log at the index
  # of the message that triggered this LLM call (the user
  # message on a fresh turn, the tool message on a
  # continuation). When the stream completes that message
  # already exists and the api_log gets attached directly via
  # `append_to_existing_message/3` — so it doesn't sit in
  # `pending_api_logs` keyed at the new assistant index. The
  # error path can't read it there.
  # Read any `api_logs` already attached to that message (the
  # trailing user/tool message) and carry them over onto the
  # error assistant message so the API Logs panel surfaces
  # the request payload alongside the error.
  defp triggering_message_api_logs(state) do
    case List.last(state.chat_state.messages) do
      {_, %{api_logs: logs}} when is_list(logs) -> logs
      _ -> []
    end
  end
end
