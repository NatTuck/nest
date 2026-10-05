defmodule Nest.Agents.Agent.Handlers.TurnHandler do
  @moduledoc """
  State transitions for the Agent's chat-turn lifecycle.

  The turn now runs in-process (see `Nest.Agents.Agent.Turn`), so the
  driver calls the `*_state/1` functions directly. The `handle/2`
  clauses remain for lifecycle messages that other code (or tests)
  still send: `{:chat_idle, _}`, `{:chat_stopped, _}`,
  `{:chat_crashed,_,_}`, `{:set_crossed_thresholds,_}` and
  `{:set_context_projection,_}`.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.SubAgent
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.LLM.Client
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Streaming

  require Logger

  @doc """
  Dispatch a lifecycle message. Returns the GenServer reply tuple.
  """
  @spec handle(term(), Agent.t()) :: GenServer.reply()
  def handle({:chat_idle, _pid}, state), do: {:noreply, chat_idle_state(state)}
  def handle({:chat_stopped, _pid}, state), do: {:noreply, chat_stopped_state(state)}

  def handle({:chat_crashed, exception, stacktrace}, state) do
    {:noreply, chat_crashed_state(exception, stacktrace, state)}
  end

  def handle({:set_crossed_thresholds, set}, state) do
    {:noreply, set_crossed_thresholds(set, state)}
  end

  def handle({:set_context_projection, tokens}, state) do
    {:noreply, set_context_projection(tokens, state)}
  end

  @doc """
  End-of-turn: clear the live partial, transition to idle, notify the
  parent, and drain the async inbox. Returns the updated state.
  """
  @spec chat_idle_state(Agent.t()) :: Agent.t()
  def chat_idle_state(state) do
    state = %{
      state
      | live: %{
          state.live
          | machine: Machine.to_idle(state.live.machine),
            streaming_acc: nil,
            cancelled: false,
            tool_index_map: %{},
            context_projection: nil
        }
    }

    Broadcasts.status(state)

    state = maybe_notify_parent_on_idle(state)
    Inbox.drain_if_idle(state)
  end

  @doc """
  User-initiated stop: finalize the partial with `stopped_by_user`
  metadata and return to idle.
  """
  @spec chat_stopped_state(Agent.t()) :: Agent.t()
  def chat_stopped_state(state), do: force_idle(state, stopped_metadata())

  @doc """
  An unexpected crash: finalize the partial with `error` metadata,
  broadcast `chat:error` (unless benign), and return to idle.
  """
  @spec chat_crashed_state(term(), list(), Agent.t()) :: Agent.t()
  def chat_crashed_state(exception, stacktrace, state) do
    state = finalize_partial_if_any(state, error_metadata())
    error_msg = format_chat_task_error(exception, stacktrace)

    if benign_chat_crash?(exception) do
      state = idle_after_crash(state, :idle, %{})
      Broadcasts.status(state)
      notify_parent_of_failure(state, crash_reason(exception))
      Inbox.drain_if_idle(state)
    else
      Logger.error(fn ->
        "[agent:#{state.name}] chat_crashed msg_index=#{state.chat_state.next_message_index} ::\n" <>
          Exception.format(:error, exception, stacktrace)
      end)

      Broadcasts.error(
        state.space_id,
        state.name,
        state.chat_state.next_message_index,
        error_msg,
        "Turn.run/2"
      )

      state = idle_after_crash(state, :idle, %{})
      Broadcasts.status(state)
      notify_parent_of_failure(state, crash_reason(exception))
      Inbox.drain_if_idle(state)
    end
  end

  defp idle_after_crash(state, _status, _extra) do
    %{
      state
      | live: %{
          state.live
          | machine: Machine.to_idle(state.live.machine),
            cancelled: false,
            turn: %Nest.Agents.Agent.ChatState.Live.Turn{}
        }
    }
  end

  @doc """
  Force the agent back to `:idle` from any busy state. Idempotent: a
  no-op when the agent is already idle with no in-flight turn/partial.
  """
  @spec force_idle(Agent.t(), map()) :: Agent.t()
  def force_idle(state, metadata \\ stopped_metadata()) do
    state = SubAgent.stop_pending_children(state)

    if idle_and_clear?(state) do
      state
    else
      finalize_stopped(state, metadata)
    end
  end

  defp idle_and_clear?(state) do
    Machine.status_for(state.live.machine) == :idle and is_nil(state.live.streaming_acc) and
      is_nil(state.live.turn.ctx)
  end

  defp finalize_stopped(state, metadata) do
    state = finalize_partial_if_any(state, metadata)

    state = %{
      state
      | live: %{
          state.live
          | machine: Machine.to_idle(state.live.machine),
            cancelled: false,
            turn: %Nest.Agents.Agent.ChatState.Live.Turn{}
        }
    }

    Broadcasts.status(state)
    notify_parent_of_failure(state, :stopped)
    state
  end

  @doc """
  A turn could not be started (worker/supervisor saturated). Force idle
  and surface an error.
  """
  @spec spawn_failed(Agent.t(), String.t()) :: Agent.t()
  def spawn_failed(state, reason) do
    state = force_idle(state, error_metadata())

    Broadcasts.error(
      state.space_id,
      state.name,
      state.chat_state.next_message_index,
      "Could not start chat turn: #{reason}",
      "Turn.spawn/4"
    )

    state
  end

  # --- helpers ---

  defp maybe_notify_parent_on_idle(state) do
    case state.tree_position.parent_name do
      nil -> state
      parent_name -> notify_parent_on_idle(parent_name, state)
    end
  end

  defp notify_parent_on_idle(parent_name, state) do
    total_usage =
      Broadcasts.total_usage(
        state.llm_metrics.usage_totals,
        state.llm_metrics.descendant_usage
      )

    response = last_assistant_text(state)

    GenServer.cast(
      AgentsRegistry.via_tuple(state.space_id, parent_name),
      {:child_completed, state.name, response, total_usage}
    )

    state
  end

  defp last_assistant_text(state) do
    case Enum.reverse(state.chat_state.messages) do
      [{:assistant, %{parts: parts}} | _] when is_list(parts) ->
        Client.text_from_parts(parts)

      _ ->
        ""
    end
  end

  defp notify_parent_of_failure(state, reason) do
    case state.tree_position.parent_name do
      nil ->
        :ok

      parent_name ->
        GenServer.cast(
          AgentsRegistry.via_tuple(state.space_id, parent_name),
          {:child_failed, state.name, reason}
        )
    end
  end

  defp crash_reason(%{__exception__: true} = exception),
    do: {:crashed, Exception.message(exception)}

  defp crash_reason(other), do: {:crashed, inspect(other)}

  defp benign_chat_crash?(%RuntimeError{message: message}) do
    String.contains?(message, "{GenServer, :call,") and
      (String.contains?(message, ":normal,") or
         String.contains?(message, ":noproc,") or
         String.contains?(message, ":shutdown,"))
  end

  defp benign_chat_crash?(_), do: false

  defp set_crossed_thresholds(%MapSet{} = set, state) do
    %{state | live: %{state.live | crossed_thresholds: set}}
  end

  defp set_crossed_thresholds(_other, state), do: state

  defp set_context_projection(tokens, state) when is_integer(tokens) and tokens >= 0 do
    state = %{state | live: %{state.live | context_projection: tokens}}
    Broadcasts.status(state)
    state
  end

  defp set_context_projection(_other, state), do: state

  defp finalize_partial_if_any(state, metadata) do
    state
    |> terminal_messages(metadata)
    |> Enum.reduce(state, fn message, acc ->
      {_stamped, acc} = Nest.Agents.Agent.__append_message__(acc, message)
      acc
    end)
    |> clear_streaming()
  end

  defp clear_streaming(state) do
    %{state | live: %{state.live | streaming_acc: nil, tool_index_map: %{}}}
  end

  defp terminal_messages(state, metadata) do
    messages = state.chat_state.messages

    case partial_message(state.live.streaming_acc, metadata) do
      nil ->
        recovery_messages(messages, metadata)

      partial ->
        case MessageList.last_wire_role(messages) do
          :assistant -> recovery_messages(messages, metadata)
          _ -> [partial]
        end
    end
  end

  defp recovery_messages(messages, metadata) do
    messages
    |> MessageList.pairing_bridge(MessageList.continuation_prompt())
    |> Enum.map(&tag_metadata(&1, metadata))
  end

  defp partial_message(nil, _metadata), do: nil

  defp partial_message(acc, metadata) do
    case Streaming.partial_message(acc, metadata) do
      {:assistant, %Assistant{parts: []}} -> nil
      partial -> partial
    end
  end

  defp tag_metadata({:assistant, %Assistant{} = msg}, metadata),
    do: {:assistant, %{msg | metadata: metadata}}

  defp tag_metadata(other, _metadata), do: other

  defp stopped_metadata, do: %{"stopped_by_user" => true}
  defp error_metadata, do: %{"error" => true}

  @stacktrace_snippet_frames 5
  @stacktrace_snippet_max_bytes 2000

  defp format_chat_task_error(exception, stacktrace) do
    formatted = Exception.format(:error, exception, stacktrace)
    snippet = take_stacktrace_frames(formatted, @stacktrace_snippet_frames)
    truncate_string(snippet, @stacktrace_snippet_max_bytes)
  end

  defp take_stacktrace_frames(formatted, n) do
    lines = String.split(formatted, "\n")

    {header, frames} =
      Enum.split_while(lines, fn line ->
        not String.starts_with?(line, "    ")
      end)

    Enum.take(frames, n)
    |> Kernel.++(if(length(frames) > n, do: ["    ..."], else: []))
    |> Enum.concat(header)
    |> Enum.join("\n")
  end

  defp truncate_string(s, max) when byte_size(s) <= max, do: s

  defp truncate_string(s, max) do
    binary_part(s, 0, max) <> "\n...(truncated)"
  end
end
