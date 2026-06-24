defmodule Nest.Agents.Agent.ChatTurn.HTTPWorker do
  @moduledoc """
  The HTTP worker body for a ChatTurn. Runs in a Task
  under `Nest.Agents.TaskSupervisor`. Calls
  `Nest.LLM.Runner.request/2` with streaming callbacks
  that re-broadcast deltas through the Agent.

  Extracted from `ChatTurn` to keep the iteration state
  machine under the credo line and complexity limits.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.LLM.RunResponse

  require Logger

  @doc """
  Run the HTTP call with the given `messages`. Sends
  `{:http_response, response}`, `{:http_error, _}`, or
  `{:worker_crashed, _, _}` to the `chat_turn_pid` on
  completion.
  """
  @spec run(map(), pid(), list()) :: :ok
  def run(state, chat_turn_pid, messages) do
    callbacks = build_callbacks(state, messages)

    ctx_with_messages = %{state.ctx | messages: messages}

    try do
      dispatch_result(Nest.LLM.Runner.request(ctx_with_messages, callbacks), chat_turn_pid)
    catch
      kind, reason ->
        forward_crash(kind, reason, __STACKTRACE__, state.ctx.agent_id, chat_turn_pid)
    end
  end

  # Dispatch the result of the HTTP call. A clean
  # `{:ok, response}` sends the response to the
  # ChatTurn; cooperative stops and stream-level errors
  # are no-ops (the Agent's `llm_error` handler already
  # ran via the `on_error` callback).
  defp dispatch_result({:ok, %RunResponse{} = response}, chat_turn_pid) do
    send(chat_turn_pid, {:http_response, response})
  end

  defp dispatch_result({:ok, nil}, _chat_turn_pid), do: :ok
  defp dispatch_result({:error, _reason}, _chat_turn_pid), do: :ok

  # The HTTP worker raised an unhandled exception. Log
  # it and forward the exception + stacktrace to the
  # ChatTurn as a `worker_crashed` message. The
  # ChatTurn forwards it to the Agent as `chat_crashed`
  # so the Agent's `chat_crashed/3` handler can
  # finalize the partial, broadcast `chat:error`, and
  # transition to `:idle`.
  defp forward_crash(kind, reason, stacktrace, agent_id, chat_turn_pid) do
    Logger.error(fn ->
      "[agent_chat_turn] HTTP worker CRASHED: agent_id=#{agent_id} kind=#{kind} reason=#{inspect(reason)}\n" <>
        Exception.format(kind, reason, stacktrace)
    end)

    exception =
      case reason do
        %{__exception__: _} = ex -> ex
        other -> %RuntimeError{message: inspect(other)}
      end

    send(chat_turn_pid, {:worker_crashed, exception, stacktrace})
    :ok
  end

  # Build the streaming callbacks for `LLM.Runner.request/2`.
  # Each callback re-broadcasts the event through the
  # Agent (via `Broadcasts`) and forwards a tagged message
  # to the Agent's GenServer (for state updates and the
  # streaming_acc mirror). The `should_stop` callback reads
  # the chat_turn_pid's mailbox for a `{:stop_chat, _}`
  # message; when set, replies `:stopped` and returns
  # `true` to halt the stream.
  #
  # The `on_error` callback only sends `{:llm_error, msg}` to
  # the Agent — it does NOT broadcast `chat:error` directly.
  # The Agent's `LLMStreamHandler.llm_error/2` handler is the
  # single source of `chat:error` events (one per error).
  defp build_callbacks(state, _messages) do
    agent_id = state.ctx.agent_id
    # The assistant message's stamped index is the Agent's
    # `next_message_index` (queried at the start of this
    # iteration). The delta broadcasts go to that index.
    acc_index = state.active_message_index

    %{
      on_text: fn text, sent ->
        Broadcasts.delta_text(agent_id, acc_index, text, sent.chars)
        send(state.agent_pid, {:delta_received, text, :text})
        %{sent | chars: sent.chars + String.length(text)}
      end,
      on_thinking: fn text, sent ->
        Broadcasts.delta_thinking(agent_id, acc_index, text, sent.chars)
        send(state.agent_pid, {:delta_received, text, :thinking})
        %{sent | chars: sent.chars + String.length(text)}
      end,
      on_signature: fn _sig ->
        :ok
      end,
      on_error: fn error ->
        error_msg = Nest.LLM.Runner.format_error(error)
        send(state.agent_pid, {:llm_error, error_msg})
      end,
      on_response: fn _response ->
        :ok
      end,
      should_stop: &check_should_stop?/0
    }
  end

  # Non-blocking mailbox check for `{:stop_chat, _}`.
  # When set, replies `:stopped` to `from` and returns
  # `true` so the stream halts.
  defp check_should_stop? do
    receive do
      {:stop_chat, from} ->
        send(from, :stopped)
        true
    after
      0 -> false
    end
  end
end
