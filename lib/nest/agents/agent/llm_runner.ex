defmodule Nest.Agents.Agent.LLMRunner do
  @moduledoc """
  Runs the LLM call chain for an agent. Takes a `RunContext` (the
  request to make) and a `RunState` (the runner's iteration state),
  drives the canonical event stream, executes tool calls, and
  returns the updated `RunState`.

  Communicates with the GenServer via `send/2` only — never touches
  the Agent state struct directly. All state mutations happen on
  the GenServer side via the messages the runner sends
  (`:delta_received`, `:thinking_signature_received`,
  `:llm_usage`, `:tool_calls_received`, `:tool_results_received`,
  `:llm_error`).
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.LLMRunner.LateCallHandlers
  alias Nest.LLM.Client
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer

  require Logger

  defmodule RunContext do
    @moduledoc false
    defstruct client_config: nil,
              tools: [],
              tool_choice: :auto,
              messages: [],
              agent_pid: nil,
              agent_id: nil,
              caps: nil,
              context_limit: nil,
              context_limit_source: nil
  end

  defmodule RunState do
    @moduledoc false
    defstruct message_index: 0,
              active_message_index: 0,
              api_log_sequences: %{},
              max_iterations: nil,
              force_finalize: false
  end

  @type run_context :: RunContext.t()
  @type run_state :: RunState.t()

  # Public API

  @doc """
  Runs the LLM call chain. Returns the updated `RunState` with
  `api_log_sequences` reflecting the new request/response log IDs.
  """
  @spec run(RunContext.t(), RunState.t()) :: RunState.t()
  def run(%RunContext{} = ctx, %RunState{} = state), do: run_with_new_client(ctx, state)

  # New client path. Consumes the canonical event stream, drives the
  # accumulator via the GenServer's handle_info, and recursively
  # handles tool calls until the LLM returns a final response or
  # the iteration cap is hit.
  defp run_with_new_client(%RunContext{} = ctx, %RunState{max_iterations: 0} = state) do
    Logger.warning(
      "Agent #{ctx.agent_id} reached max tool iterations, making final call without tools"
    )

    Broadcasts.notification(ctx.agent_id, %{
      type: "max_iterations",
      message: "Max tool iterations reached"
    })

    # Make one final LLM call with tools disabled (both tools and tool_choice)
    # so the LLM sees the tool results and produces a text response
    final_ctx = %{ctx | tools: nil, tool_choice: :none}

    state = broadcast_request_log(final_ctx, state)
    {:ok, stream} = run_request(final_ctx)
    handle_new_stream(final_ctx, state, stream)
  end

  defp run_with_new_client(%RunContext{} = ctx, %RunState{} = state) do
    case run_preflight(ctx) do
      {:compacted, new_messages} ->
        run_with_new_client(%{ctx | messages: new_messages}, state)

      {:proceed, messages} ->
        ctx = %{ctx | messages: messages}
        Logger.info("Agent #{ctx.agent_id} sending LLM request (message #{state.message_index})")
        state = broadcast_request_log(ctx, state)
        {:ok, stream} = run_request(ctx)
        handle_new_stream(ctx, state, stream)

      :stopped ->
        raise Nest.Agents.Agent.ToolLoop.StoppedError
    end
  end

  # Asks the GenServer to run a pre-flight check. Returns `:proceed`,
  # `{:compacted, new_messages}`, or `:stopped` if the user interrupted.
  defp run_preflight(ctx) do
    send(ctx.agent_pid, {:preflight_request, self(), ctx.messages})

    receive do
      {:preflight_result, :proceed, messages} ->
        {:proceed, messages}

      {:preflight_result, :compacted, new_messages} ->
        {:compacted, new_messages}

      {:stop_chat, from} ->
        send(from, :stopped)
        :stopped
    after
      30_000 ->
        Logger.warning("Pre-flight request timed out; proceeding with existing messages")
        {:proceed, ctx.messages}
    end
  end

  defp broadcast_request_log(ctx, %RunState{} = state) do
    request = build_run_request(ctx)
    opts = build_run_opts(ctx)

    sequences =
      broadcast_new_request_log(
        ctx.client_config,
        request,
        opts,
        ctx.agent_pid,
        state.active_message_index,
        state.api_log_sequences
      )

    %{state | api_log_sequences: sequences}
  end

  defp build_run_request(ctx) do
    %RunRequest{
      # System messages (initial at position 0, late reminders at
      # later positions) stay in the messages array. Each client
      # shapes them for its wire protocol.
      messages: ctx.messages,
      tools: ctx.tools,
      tool_choice: ctx.tool_choice,
      model: ctx.client_config.model,
      metadata: %{}
    }
  end

  defp build_run_opts(ctx) do
    [
      base_url: ctx.client_config.base_url,
      api_key: ctx.client_config.api_key,
      receive_timeout: ctx.client_config.receive_timeout,
      # Threaded through opts so a test's per-agent mock client (e.g.
      # `Nest.LLM.MockClient` in `lib/nest/llm/mock_client.ex`) can
      # find the queue scoped to this agent pid. The real
      # OpenAI/Anthropic clients ignore unknown keys.
      agent_pid: ctx.agent_pid
    ]
  end

  defp run_request(ctx) do
    ctx.client_config.client.run(build_run_request(ctx), build_run_opts(ctx))
  end

  @spec handle_new_stream(RunContext.t(), RunState.t(), Enumerable.t()) :: RunState.t()
  defp handle_new_stream(ctx, state, stream) do
    result = consume_new_stream(stream, state.message_index, ctx.agent_id, ctx.agent_pid)
    dispatch_reducer_result(ctx, state, result)
  end

  # Dispatch on the reducer's 4-tuple. The reducer's typespec
  # declares `response` as `term() | nil` but the type checker
  # infers `%RunResponse{} | nil` from the dispatch clauses. We
  # use `is_struct/2` (a runtime guard) to test the response
  # without triggering the static type checker's
  # "comparison between distinct types" warning.
  @spec dispatch_reducer_result(RunContext.t(), RunState.t(), tuple()) :: RunState.t()
  defp dispatch_reducer_result(ctx, state, {_acc, response, error, _sent}) do
    cond do
      error != nil ->
        handle_failed_response(state, error, ctx)

      not is_struct(response, RunResponse) ->
        raise Nest.Agents.Agent.ToolLoop.StoppedError

      true ->
        handle_new_response(ctx, state, response)
    end
  end

  defp handle_new_response(ctx, state, response) do
    sequences =
      broadcast_new_response_log(
        ctx.agent_pid,
        state.message_index,
        state.api_log_sequences,
        response
      )

    state = %{state | api_log_sequences: sequences}

    # Forward usage to the GenServer so the running totals update
    # and the next chat:status push carries the fresh numbers.
    # `usage` is `nil` for clients that don't populate it; the merge
    # helper treats nil as a no-op.
    send(ctx.agent_pid, {:llm_usage, response.usage})

    cond do
      state.force_finalize ->
        # Second-chance call after max-iterations: force-finalize
        # regardless of what the LLM returned, so we don't loop
        # forever if it ignores `tool_choice: :none` again.
        send_final_assistant(ctx, state, response)

      state.max_iterations <= 0 and RunResponse.has_tool_calls?(response) ->
        handle_max_iterations_with_tool_calls(ctx, state, response)

      RunResponse.has_tool_calls?(response) ->
        run_with_new_client_after_tool_calls(ctx, state, response)

      true ->
        send_final_assistant(ctx, state, response)
    end
  end

  defp send_final_assistant(ctx, state, response) do
    send(ctx.agent_pid, {:llm_response_with_thinking, response, response.thinking})
    # The terminal path returns the state so the caller's
    # `Task.Supervisor.start_child/2` body can destructure
    # `%RunState{api_log_sequences: _}`. `api_log_sequences`
    # returned by `run_with_new_client_after_tool_calls/3`
    # flows through unchanged; the final path threads it.
    state
  end

  # The LLM hit the iteration cap and we made the final call with
  # `tools: nil, tool_choice: :none`. If the LLM still emitted tool
  # calls anyway (some providers don't honor `tool_choice: :none`),
  # give it one more chance: synthesize error tool results so it
  # sees the constraint, then call again with `force_finalize: true`
  # so the second-chance text becomes the final answer no matter
  # what.
  defp handle_max_iterations_with_tool_calls(ctx, state, response) do
    Logger.warning(
      "Agent #{ctx.agent_id} LLM emitted tool calls on max-iterations " <>
        "final call; sending synthetic errors and trying once more"
    )

    {tool_call_message, tool_result_message, messages_with_synthesized} =
      LateCallHandlers.build_synthetic_error_pair(ctx, state, response)

    send(ctx.agent_pid, {:tool_calls_received, tool_call_message})
    send(ctx.agent_pid, {:tool_results_received, tool_result_message})

    # Recurse with the second-chance flag, no tools, and
    # `max_iterations: 0` (the second-chance call doesn't get its
    # own tool budget). `force_finalize: true` makes
    # `handle_new_response/3` always return the text response.
    next_state = %RunState{
      message_index: state.message_index + 2,
      active_message_index: state.message_index + 1,
      api_log_sequences: state.api_log_sequences,
      max_iterations: 0,
      force_finalize: true
    }

    run_with_new_client(
      %{ctx | messages: messages_with_synthesized, tools: nil, tool_choice: :none},
      next_state
    )
  end

  defp run_with_new_client_after_tool_calls(ctx, state, response) do
    {tool_call_message, tool_result_message, updated_messages} =
      LateCallHandlers.build_tool_pair(ctx, state, response)

    send(ctx.agent_pid, {:tool_calls_received, tool_call_message})
    send(ctx.agent_pid, {:tool_results_received, tool_result_message})

    next_state = %RunState{
      message_index: state.message_index + 2,
      active_message_index: state.message_index + 1,
      api_log_sequences: state.api_log_sequences,
      max_iterations: state.max_iterations - 1
    }

    messages_with_reminder =
      LateCallHandlers.maybe_inject_budget_warning(
        updated_messages,
        ctx,
        next_state.max_iterations,
        ctx.agent_pid
      )

    run_with_new_client(
      %{ctx | messages: messages_with_reminder},
      next_state
    )
  end

  @spec consume_new_stream(Enumerable.t(), non_neg_integer(), String.t(), pid()) ::
          {Client.accumulator(), RunResponse.t() | nil, term() | nil, map()}
  defp consume_new_stream(stream, message_index, agent_id, agent_pid) do
    consumer = %StreamConsumer{
      on_text: &broadcast_text_delta(&1, &2, message_index, agent_id, agent_pid),
      on_thinking: &forward_thinking_delta(&1, &2, message_index, agent_id, agent_pid),
      # Anthropic's extended thinking emits a signature that
      # must be echoed back on subsequent turns. Forward it
      # to the agent pid so it can be persisted in the
      # assistant message's metadata.
      on_signature: &send(agent_pid, {:thinking_signature_received, &1}),
      # Cooperative stop check: the chat task is the one
      # consuming the stream, so it must read its own
      # mailbox to detect a `{:stop_chat, _}` from the agent.
      # We non-blockingly check (`:receive, 0`) on every
      # event; if the stop message is there, the stream halts
      # and the consumer returns `response: nil`, which the
      # caller (`handle_new_stream/3`) translates to a
      # `ToolLoop.StoppedError` raise.
      should_stop: fn -> chat_task_should_stop?() end
    }

    {acc, response, error, sent} = StreamConsumer.reduce(stream, consumer)

    # Preserve the `nil` response when the stream halted (user
    # clicked Stop). `normalize_response/2` would otherwise
    # synthesize a `%RunResponse{}` from the accumulator, which
    # would make the dispatcher think the stream completed
    # normally.
    final_response =
      if response == nil do
        nil
      else
        normalize_response(response, acc)
      end

    # `sent` carries chars-sent counters used for delta broadcasting;
    # the running total is already in `acc`'s text buffer at this point.
    _ = sent
    {acc, final_response, error, sent}
  end

  # Non-blocking mailbox check for a `{:stop_chat, _}` message.
  # Returns `true` if the chat task should halt the current
  # stream iteration. Used by the StreamConsumer's cooperative
  # `should_stop` callback so non-mailbox-backed streams (e.g.
  # the test mock client) can be interrupted between events.
  # The `after 0` yields to the scheduler so the agent's
  # `handle_info({:stop_chat, _}, state)` can run between
  # events and deliver the stop to the chat task's mailbox.
  defp chat_task_should_stop? do
    receive do
      {:stop_chat, from} ->
        send(from, :stopped)
        true
    after
      0 -> false
    end
  end

  defp broadcast_text_delta(text, sent, message_index, agent_id, agent_pid) do
    Broadcasts.delta_text(agent_id, message_index, text, sent.chars)
    send(agent_pid, {:delta_received, text, :text})
    %{sent | chars: sent.chars + String.length(text)}
  end

  defp forward_thinking_delta(text, sent, message_index, agent_id, agent_pid) do
    Broadcasts.delta_thinking(agent_id, message_index, text, sent.chars)
    send(agent_pid, {:delta_received, text, :thinking})
    %{sent | chars: sent.chars + String.length(text)}
  end

  # The accumulator is the source of truth for parsed tool calls.
  # The :done event's response.tool_calls (when set) carries whatever the
  # client decided to put there, which may be plain maps (mock) or
  # `Nest.LLM.Tool` structs. We replace it with the accumulator's
  # normalized `Nest.Messages.ToolCall` list so downstream consumers
  # can pattern-match on the struct. `usage` is propagated from the
  # accumulator too, since some clients (and the test mock) emit
  # `{:usage, _}` events without echoing the value back into the
  # `:done` response payload.
  defp normalize_response(nil, acc) do
    Client.finalize(acc, nil)
  end

  defp normalize_response(%RunResponse{} = response, acc) do
    finalized = Client.finalize(acc, response.model)

    %{
      response
      | tool_calls: finalized.tool_calls,
        text: response.text || finalized.text,
        thinking: response.thinking || finalized.thinking,
        thinking_signature: response.thinking_signature || finalized.thinking_signature,
        usage: response.usage || finalized.usage
    }
  end

  defp broadcast_new_request_log(
         client_config,
         request,
         opts,
         agent_pid,
         active_message_index,
         api_log_sequences
       ) do
    payload = client_config.client.format_request_payload(request, opts)

    {api_log_id, updated_sequences} =
      Broadcasts.next_api_log_id(active_message_index, api_log_sequences)

    Broadcasts.api_log(agent_pid, active_message_index, api_log_id, payload)
    updated_sequences
  end

  defp broadcast_new_response_log(agent_pid, message_index, api_log_sequences, response) do
    payload = Broadcasts.api_response_from_run(response)
    {api_log_id, updated_sequences} = Broadcasts.next_api_log_id(message_index, api_log_sequences)
    Broadcasts.api_response(agent_pid, message_index, api_log_id, payload)
    updated_sequences
  end

  defp handle_failed_response(state, error, ctx) do
    error_msg = format_error(error)

    # `Broadcasts.error/4` is the centralized error path: it logs
    # the failure (with agent_id, message_index, and source) and
    # broadcasts the `chat:error` event with a `[Source: ...]`
    # tag so the UI shows where the error originated.
    Broadcasts.error(
      ctx.agent_id,
      state.message_index,
      error_msg,
      "LLMRunner.handle_failed_response/3"
    )

    # Notify agent that streaming failed (similar to successful response)
    send(ctx.agent_pid, {:llm_error, error_msg})

    # Return the state so the caller's
    # `Task.Supervisor.start_child/2` body can destructure
    # `%RunState{api_log_sequences: _}`. Sequences are unchanged
    # on the failure path — no new request log was generated.
    state
  end

  defp format_error({type, status, ""}), do: "Error: HTTP #{status}: #{type}"

  defp format_error({type, status, body}),
    do: "Error: HTTP #{status}: #{type}\n#{truncate_body(body)}"

  defp format_error(error), do: "Error: #{inspect(error)}"

  defp truncate_body(""), do: ""
  defp truncate_body(nil), do: ""

  defp truncate_body(body) when is_binary(body) do
    if String.length(body) > 500,
      do: String.slice(body, 0, 500) <> "\n...(truncated)",
      else: body
  end

  defp truncate_body(other), do: inspect(other)
end
