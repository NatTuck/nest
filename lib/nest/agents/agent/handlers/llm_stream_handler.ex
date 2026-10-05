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
  update `state.live.streaming_acc` (the authoritative
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
  alias Nest.Agents.Agent.Handlers.LLMStreamHandler.FileAccess
  alias Nest.Agents.Agent.Handlers.TurnHandler
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn.Idle
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
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
    # A stop is already in flight and the timer owns the single terminal
    # transition; an error arriving from the (about-to-be-killed) worker
    # must not finalize a second time.
    if state.live.cancelled or Machine.stopping?(state.live.machine) do
      {:noreply, state}
    else
      {:noreply, llm_error_state(error_msg, state)}
    end
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
    acc = state.live.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      chars_start = acc.chars_sent
      new_acc = Streaming.append_text(acc, delta_content)
      Broadcasts.delta_text(state.space_id, state.name, new_acc.index, delta_content, chars_start)
      {:noreply, %{state | live: %{state.live | streaming_acc: new_acc}}}
    end
  end

  defp delta_received(delta_content, :thinking, state) do
    acc = state.live.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      # `chars_sent` tracks text + thinking combined (see
      # `Streaming.append_thinking/3`), so the same
      # `acc.chars_sent` works as `chars_start` for both
      # text and thinking deltas.
      chars_start = acc.chars_sent
      new_acc = Streaming.append_thinking(acc, delta_content)

      Broadcasts.delta_thinking(
        state.space_id,
        state.name,
        new_acc.index,
        delta_content,
        chars_start
      )

      {:noreply, %{state | live: %{state.live | streaming_acc: new_acc}}}
    end
  end

  # Tool-use streaming. The HTTP worker forwards
  # `{:tool_call_start, %{id, name, index}}` and
  # `{:tool_call_delta, %{id, index, arguments_delta}}` from
  # the LLM client's canonical event stream. We broadcast
  # them as `chat:delta` with `part_type: :tool_use_start`
  # / `:tool_use_delta` so the JS streaming partial can
  # render the in-flight tool call. The `tool_index_map`
  # resolves `:by_index` ids (Anthropic's
  # `input_json_delta` for tool calls) into the concrete
  # tool-call id so the JS only ever sees concrete ids.
  defp delta_received(%{id: id, name: name} = event, :tool_use_start, state) do
    acc = state.live.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      # Mock and Anthropic clients emit `tool_call_start`
      # events without an `index` field — the OpenAI client
      # always sends one. Default to 0 (single-tool turns)
      # when absent so the JS and the tool_index_map see a
      # stable key.
      index = Map.get(event, :index, 0)

      new_tool_index_map =
        if is_binary(id),
          do: Map.put(state.live.tool_index_map, index, id),
          else: state.live.tool_index_map

      new_acc = Streaming.start_tool_call(acc, id, name)

      Broadcasts.delta_tool_use_start(state.space_id, state.name, acc.index, id, name, index)

      {:noreply,
       %{
         state
         | live: %{
             state.live
             | tool_index_map: new_tool_index_map,
               streaming_acc: new_acc
           }
       }}
    end
  end

  defp delta_received(%{id: id, arguments_delta: fragment} = event, :tool_use_delta, state) do
    acc = state.live.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      # See `:tool_use_start` clause above for why we
      # default `index` to 0 here.
      index = Map.get(event, :index, 0)
      concrete_id = resolve_tool_call_id(id, index, state.live.tool_index_map)

      if concrete_id do
        Broadcasts.delta_tool_use_delta(
          state.space_id,
          state.name,
          acc.index,
          concrete_id,
          index,
          fragment
        )

        new_acc = Streaming.append_tool_call_args(acc, concrete_id, fragment)

        {:noreply,
         %{
           state
           | live: %{state.live | streaming_acc: new_acc}
         }}
      else
        {:noreply, state}
      end
    end
  end

  defp delta_received(delta_content, _part_type, state) do
    # For unsupported types, append as text for now.
    delta_received(delta_content, :text, state)
  end

  # Resolve an LLM-emitted tool-call id to a concrete string id.
  # Anthropic's `input_json_delta` events (and OpenAI's
  # subsequent tool-call deltas) use `id: :by_index` with the
  # block's index, so we look it up in the running map seeded
  # by `tool_use_start` events. Returns `nil` if the index
  # isn't known yet — the JS doesn't get a delta for it (the
  # next `tool_use_start` will arrive and we'll catch up).
  defp resolve_tool_call_id(id, _index, _map) when is_binary(id), do: id

  defp resolve_tool_call_id(:by_index, index, map) do
    Map.get(map, index)
  end

  defp resolve_tool_call_id(_other, _index, _map), do: nil

  # Anthropic's extended thinking emits a signature alongside the
  # thinking content. Stash it on the streaming accumulator so it
  # round-trips into the persisted assistant message's metadata.
  defp thinking_signature_received(signature, state) do
    new_acc = %{state.live.streaming_acc | thinking_signature: signature}
    {:noreply, %{state | live: %{state.live | streaming_acc: new_acc}}}
  end

  # Finalize error message. The HTTP worker sent us the
  # formatted error string; we are the single source of
  # `chat:error` events (the worker no longer broadcasts
  # directly — that double-broadcast was a bug). The error
  # is broadcast with the `[Source: Turn.run/2]`
  # tag so the user can grep the server log for the matching
  # entry.
  #
  # Public so the in-process driver can finalize an error stream
  # directly (see `Turn.ResponseHandler`'s empty-response case) and
  # keep the `chat:error` broadcast ordered before the idle status.
  @doc false
  @spec llm_error_state(String.t(), Nest.Agents.Agent.t()) :: Nest.Agents.Agent.t()
  def llm_error_state(error_msg, state) do
    error_message = build_error_message(error_msg, state)

    case Nest.Agents.Agent.__append_message__(state, error_message) do
      {:ok, stamped, state} ->
        stamped_index = Nest.Agents.Agent.stamped_index(stamped)
        state = %{state | live: %{state.live | streaming_acc: nil, tool_index_map: %{}}}

        Broadcasts.error(
          state.space_id,
          state.name,
          stamped_index,
          error_msg,
          "Turn.run/2"
        )

        Idle.enter(state)

      {:invalid, reason, state} ->
        TurnHandler.invalid_append_state(state, reason)
    end
  end

  # Preserve whatever the model streamed before the failure (a dropped
  # or stalled connection) and append the error text, so nothing the
  # model produced is silently lost. Tagged `error` so the UI renders
  # the failure indicator and doesn't expect a response log. A `nil`
  # accumulator (nothing streamed) degrades to an error-only message.
  defp build_error_message(error_msg, state) do
    error_part = %Part.Text{text: "\n\n" <> error_msg}

    case state.live.streaming_acc do
      %Streaming.AssistantAccumulator{} = acc ->
        {:assistant, partial} = Streaming.partial_message(acc, %{"error" => true})
        {:assistant, %{partial | parts: partial.parts ++ [error_part]}}

      _ ->
        {:assistant,
         %Assistant{
           index: nil,
           timestamp: DateTime.utc_now(),
           parts: [error_part],
           api_logs: [],
           metadata: %{"error" => true}
         }}
    end
  end

  # Tool-call responses are persisted only once their batch is confirmed
  # to fit; the in-process driver calls this directly.
  @doc false
  def tool_calls_received(tool_call_message, state) do
    case persist_assistant(tool_call_message, state) do
      {:ok, state} -> {:noreply, state}
      {:invalid, reason, state} -> {:noreply, TurnHandler.invalid_append_state(state, reason)}
    end
  end

  # Append an assistant message and move to the tools phase. Returns a
  # tagged result so the in-process driver can stop the turn on a broken
  # sequence instead of crashing the Agent.
  @doc false
  @spec persist_assistant(Assistant.t(), Nest.Agents.Agent.t()) ::
          {:ok, Nest.Agents.Agent.t()} | {:invalid, String.t(), Nest.Agents.Agent.t()}
  def persist_assistant(tool_call_message, state) do
    tool_call_message = {:assistant, %{tool_call_message | index: nil}}

    case Nest.Agents.Agent.__append_message__(state, tool_call_message) do
      {:ok, _stamped, state} ->
        state = %{
          state
          | live: %{state.live | machine: Machine.to_chat_tools(state.live.machine)}
        }

        Broadcasts.status(state)
        {:ok, state}

      {:invalid, reason, state} ->
        {:invalid, reason, state}
    end
  end

  @doc false
  def tool_results_received(tool_result_message, state) do
    tool_result_message = {:tool, %{tool_result_message | index: nil}}

    if answers_pending_tool_use?(state.chat_state.messages, tool_result_message) do
      append_tool_result(tool_result_message, state)
    else
      # Stale/duplicate result: the tool worker's result was delivered after
      # the turn was finalized (stop/crash) and the abandoned `tool_use` was
      # already answered by the terminal recovery. Appending it would land an
      # orphan `tool_result` in an otherwise-closed sequence. Drop it.
      Logger.warning(
        "[agent:#{state.name}] ignoring a tool result that does not answer the trailing " <>
          "tool_use (status=#{Machine.status_for(state.live.machine)}); dropping stale/duplicate result"
      )

      {:noreply, state}
    end
  end

  # `tool_results_received/2` only calls this after the staleness guard
  # confirms the result answers the trailing `tool_use`, so the append is
  # normally live-valid (`:ok`). A `:cannot_compact` tripwire fails the
  # turn cleanly; a `:stale` result is dropped.
  defp append_tool_result(tool_result_message, state) do
    case Nest.Agents.Agent.__append_message__(state, tool_result_message) do
      {:ok, stamped, state} ->
        stamped_index = Nest.Agents.Agent.stamped_index(stamped)

        # Update the `read_files` cache from this tool result
        # (only on success — a failed read/write shouldn't pin a
        # stale mtime into the cache). Successful `file-write`
        # is also recorded here so a follow-up `file-write` from
        # the same agent sees the new on-disk state, not the
        # pre-write state. Path resolution goes through the same
        # workspace-root convention `file-read` uses, so cache
        # keys match the policy-check keys at write time.
        state = FileAccess.record(stamped, state)

        state = %{
          state
          | live: %{
              state.live
              | machine: Machine.to_chat_generating(state.live.machine),
                streaming_acc: Streaming.new(stamped_index + 1),
                tool_index_map: %{}
            }
        }

        Broadcasts.status(state)
        {:noreply, state}

      {:invalid, reason, state} ->
        {:noreply, TurnHandler.invalid_append_state(state, reason)}

      {:stale, state} ->
        {:noreply, state}
    end
  end

  # A tool result may only be appended when the current tail is an assistant
  # `tool_use` whose ids it answers. This is the invariant that keeps a late
  # `{:tool_results_received, _}` (sent asynchronously by the turn's tool
  # worker after the turn was finalized) from appending an orphan result.
  defp answers_pending_tool_use?(messages, {:tool, %Tool{parts: parts}}) do
    pending = MessageList.unpaired_tail_tool_uses(messages)
    pending != [] and Enum.any?(pending, fn %Part.ToolUse{id: id} -> answers_id?(parts, id) end)
  end

  defp answers_id?(parts, id) do
    Enum.any?(parts || [], fn
      %Part.ToolResult{tool_call_id: ^id} -> true
      _ -> false
    end)
  end

  # The `read_files` cache update moved to
  # `Nest.Agents.Agent.Handlers.LLMStreamHandler.FileAccess` so
  # this file stays under credo's 500-line cap. The `tool_results_received/2`
  # handler above calls `FileAccess.record/2` to populate the
  # cache from each successful `file-read` / `file-write`
  # tool result.

  defp llm_usage(usage, state) do
    {:noreply, llm_usage_state(usage, state)}
  end

  # Merge per-call usage into the running totals and broadcast a fresh
  # `chat:status` so the chip can update mid-stream. Shared with the
  # in-process turn driver, which calls it directly.
  @doc false
  @spec llm_usage_state(map() | nil, Nest.Agents.Agent.t()) :: Nest.Agents.Agent.t()
  def llm_usage_state(usage, state) do
    state = %{
      state
      | llm_metrics: %{
          state.llm_metrics
          | usage_totals: Broadcasts.merge_usage_totals(state.llm_metrics.usage_totals, usage)
        }
    }

    Broadcasts.status(state)
    state
  end
end
