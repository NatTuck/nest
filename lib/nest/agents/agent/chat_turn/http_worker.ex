defmodule Nest.Agents.Agent.ChatTurn.HTTPWorker do
  @moduledoc """
  The HTTP worker body for a ChatTurn. Runs in a Task
  under `Nest.Agents.TaskSupervisor`. Calls
  `Nest.LLM.Runner.request/2` with streaming callbacks
  that re-broadcast deltas through the Agent.

  Extracted from `ChatTurn` to keep the iteration state
  machine under the credo line and complexity limits.
  """

  alias Nest.LLM.Runner
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
      dispatch_result(Runner.request(ctx_with_messages, callbacks), chat_turn_pid)
    catch
      kind, reason ->
        forward_crash(kind, reason, __STACKTRACE__, state.ctx.agent_name, chat_turn_pid)
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

  # The HTTP worker raised an unhandled exception. Forward
  # the exception + stacktrace to the ChatTurn as a
  # `worker_crashed` message. The ChatTurn forwards it to
  # the Agent as `chat_crashed` so the Agent's
  # `chat_crashed/3` handler can finalize the partial,
  # broadcast `chat:error`, and transition to `:idle`.
  #
  # For `GenServer.call` exits whose target process stopped
  # normally (`{:normal, _}`, `{:noproc, _}`, `{:shutdown, _}`
  # nested under `{GenServer, :call, _}`), skip the
  # `Logger.error` — those are not crashes, they're the
  # worker's pending call exiting because the target (the
  # MockClient queue in tests; the Agent during a stop in
  # production) was deliberately shut down. Production LLM
  # clients (`OpenAIClient`, `AnthropicClient`) use `Req` and
  # never raise these patterns — real LLM errors arrive as
  # `{:error, _}` stream events handled by `dispatch_result/2`.
  # Bare `:normal` / `:noproc` reasons (without the
  # `GenServer.call` wrapper) are still logged: a future
  # `raise`/exit that happens to be `:normal` should surface.
  # The Agent's `chat_crashed/3` handler re-checks the
  # pattern (via `benign_chat_crash?/1`) and skips both the
  # log and the `chat:error` broadcast for the same
  # pattern, so the user-visible path stays silent too.
  defp forward_crash(kind, reason, stacktrace, agent_id, chat_turn_pid) do
    if not benign_exit?(kind, reason) do
      Logger.error(fn ->
        "[agent_chat_turn] HTTP worker CRASHED: agent_id=#{agent_id} kind=#{kind} reason=#{inspect(reason)}\n" <>
          Exception.format(kind, reason, stacktrace)
      end)
    end

    exception =
      case reason do
        %{__exception__: _} = ex -> ex
        other -> %RuntimeError{message: inspect(other)}
      end

    send(chat_turn_pid, {:worker_crashed, exception, stacktrace})
    :ok
  end

  # A `GenServer.call/3` exits with the `{kind, {GenServer, :call, _}}`
  # shape when its target process terminates. If the target
  # stopped cleanly (`:normal`), was already gone (`:noproc`),
  # or was told to shut down (`:shutdown`), the call's
  # failure is a consequence of that — not a bug in this
  # worker. Bare `:normal` / `:noproc` / `:shutdown` reasons
  # without the `GenServer.call` wrapper fall through (logged
  # as a real crash) so a future exit that happens to be
  # `:normal` still surfaces.
  defp benign_exit?(:exit, {:normal, {GenServer, :call, _}}), do: true
  defp benign_exit?(:exit, {:noproc, {GenServer, :call, _}}), do: true
  defp benign_exit?(:exit, {:shutdown, {GenServer, :call, _}}), do: true
  defp benign_exit?(_kind, _reason), do: false

  # Build the streaming callbacks for `LLM.Runner.request/2`.
  # Each callback forwards a tagged message to the Agent's
  # GenServer, which updates `state.chat_state.streaming_acc`
  # and broadcasts `chat:delta`. The HTTP worker does NOT
  # broadcast directly — the Agent is the single source of
  # `chat:delta` events (avoids the race where a subscriber
  # sees the broadcast before the accumulator is updated).
  #
  # The `should_stop` callback reads the chat_turn_pid's
  # mailbox for a `{:stop_chat, _}` message; when set, replies
  # `:stopped` and returns `true` to halt the stream.
  #
  # The `on_error` callback only sends `{:llm_error, msg}` to
  # the Agent — it does NOT broadcast `chat:error` directly.
  # The Agent's `LLMStreamHandler.llm_error/2` handler is the
  # single source of `chat:error` events (one per error).
  defp build_callbacks(state, _messages) do
    %{
      on_text: fn text, sent ->
        send(state.ctx.agent_pid, {:delta_received, text, :text})
        %{sent | chars: sent.chars + String.length(text)}
      end,
      on_thinking: fn text, sent ->
        send(state.ctx.agent_pid, {:delta_received, text, :thinking})
        %{sent | chars: sent.chars + String.length(text)}
      end,
      on_signature: fn _sig ->
        :ok
      end,
      # Tool-call events are forwarded to the Agent so the JS
      # streaming partial can render the in-flight tool use as a
      # first-class `ToolCalls` card instead of waiting for the
      # message to finalize. Without this, a think-only assistant
      # message that emits a tool call stays invisible to the
      # UI until the BEAM broadcasts the assistant message.
      # The Agent resolves `:by_index` ids (Anthropic) into the
      # concrete tool-call id via its own streaming accumulator.
      on_tool_call_start: fn event, sent ->
        send(state.ctx.agent_pid, {:delta_received, event, :tool_use_start})
        sent
      end,
      on_tool_call_delta: fn event, sent ->
        send(state.ctx.agent_pid, {:delta_received, event, :tool_use_delta})
        sent
      end,
      on_error: fn error ->
        error_msg = Runner.format_error(error)
        send(state.ctx.agent_pid, {:llm_error, error_msg})
      end,
      on_response: fn _response ->
        :ok
      end,
      should_stop: fn _acc -> check_should_stop?(state) end
    }
  end

  # Cooperative halt check. Polls the Agent's `cancelled`
  # flag via `:sys.get_state/1` — a synchronous system message
  # that returns the Agent's current state. The Agent sets
  # `cancelled = true` in its `handle_call({:stop_chat, _})`
  # handler, which runs synchronously when the channel's
  # `chat:stop` push calls `Agent.stop_chat/2`.
  #
  # We check the Agent's state (not the worker's local
  # mailbox) because the stop is delivered to the chat_turn,
  # not the worker. The chat_turn is a separate process, so
  # the worker's `receive` would never see the stop. Checking
  # the Agent's state works regardless of which process the
  # stop was sent to, and the Agent's mailbox is processed
  # in FIFO order — so the system message and the stop are
  # ordered correctly: the system message returns `cancelled
  # = true` only after the Agent has processed the stop.
  #
  # The system message is a cheap round-trip (no handle_call
  # machinery), and `check_should_stop?/0` is called once per
  # stream event. For a 1000-event stream with the MockClient
  # (which yields events instantly), this adds ~1000 system
  # messages to the Agent's mailbox. Each system message is
  # processed in O(1) and doesn't block the Agent's hot path.
  defp check_should_stop?(state) do
    state.ctx.agent_pid
    |> :sys.get_state()
    |> Map.get(:live)
    |> Map.get(:cancelled)
  catch
    # Agent is gone (test cleanup, supervisor teardown).
    # Nothing to stop against; let the stream finish.
    :exit, _reason -> false
  end
end
