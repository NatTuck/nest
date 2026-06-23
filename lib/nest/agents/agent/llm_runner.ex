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
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.LLM.Client
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer
  alias Nest.Messages.Assistant
  alias Nest.Messages.Tool

  require Logger

  defmodule RunContext do
    @moduledoc false
    defstruct client_config: nil,
              tools: [],
              tool_choice: :auto,
              system_prompt: nil,
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
              max_iterations: nil
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
    # Plan §"Compaction flow": pre-flight runs at the start of
    # every LLM call site. The chat task asks the GenServer to
    # re-check (state.chat_state.messages may have grown via archived API
    # logs since the last call) and reply with either `:proceed`
    # (use the existing snapshot) or `:compacted` (use the new
    # compacted list).
    #
    # `:stopped` is returned when the agent sent a `{:stop_chat, _}`
    # while the chat task was waiting on the pre-flight. We raise
    # `ToolLoop.StoppedError` so the chat task body can detect the
    # stop and notify the agent.
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

  # Asks the GenServer to run a pre-flight check on its current
  # state.chat_state.messages. Returns `:proceed` if the next LLM call fits
  # (or no limit is known / a stream is in progress) and
  # `{:compacted, new_messages}` if the compactor ran. The chat
  # task blocks here on a `receive`, mirroring the
  # `compact_context` tool's round-trip pattern.
  #
  # The `{:stop_chat, from}` clause lets the agent interrupt the
  # chat task while it is waiting on a pre-flight compaction. The
  # chat task acknowledges the stop, sends `:stopped` back, and
  # the caller unwinds via the `:stopped` return value.
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
      # Strip leading `{:system, _}` tuples — the system prompt
      # is now carried in `system_prompt` so both providers
      # (Anthropic's top-level `system` field, OpenAI's leading
      # `system` message) can shape it without scanning the
      # messages array.
      messages: reject_system_messages(ctx.messages),
      tools: ctx.tools,
      tool_choice: ctx.tool_choice,
      model: ctx.client_config.model,
      system_prompt: ctx.system_prompt,
      metadata: %{}
    }
  end

  defp reject_system_messages(messages) do
    Enum.reject(messages, fn
      {:system, _} -> true
      _ -> false
    end)
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

    if RunResponse.has_tool_calls?(response) do
      run_with_new_client_after_tool_calls(ctx, state, response)
    else
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

  defp run_with_new_client_after_tool_calls(ctx, state, response) do
    {tool_call_message, tool_result_message, updated_messages} =
      build_tool_pair(ctx, state, response)

    send(ctx.agent_pid, {:tool_calls_received, tool_call_message})
    send(ctx.agent_pid, {:tool_results_received, tool_result_message})

    next_state = %RunState{
      message_index: state.message_index + 2,
      active_message_index: state.message_index + 1,
      api_log_sequences: state.api_log_sequences,
      max_iterations: state.max_iterations - 1
    }

    system_prompt =
      case iteration_warning(next_state.max_iterations) do
        nil ->
          ctx.system_prompt

        warning when is_binary(ctx.system_prompt) ->
          ctx.system_prompt <> "\n\n" <> warning

        warning ->
          warning
      end

    run_with_new_client(
      %{ctx | messages: updated_messages, system_prompt: system_prompt},
      next_state
    )
  end

  defp build_tool_pair(ctx, state, response) do
    tool_call_message =
      {:assistant,
       %Assistant{
         index: state.message_index,
         timestamp: DateTime.utc_now(),
         content: response.text,
         tool_calls: response.tool_calls,
         # Anthropic's extended-thinking signature, echoed back on
         # subsequent turns. The AnthropicClient reads this field
         # directly when rebuilding assistant content blocks for
         # the next request.
         thinking_signature: response.thinking_signature,
         api_logs: []
       }}

    # The BudgetPlanner runs each tool call through the budget loop
    # (fits / truncates / skips / cascade-skip). It preserves call
    # order in its output. We rebuild the ToolResult list from the
    # planner's output — the planner's strings already include
    # truncation notes and skip responses where appropriate.
    tool_results =
      ToolLoop.execute(
        ctx,
        state,
        response.tool_calls || []
      )

    tool_result_message =
      {:tool,
       %Tool{
         index: state.message_index + 1,
         timestamp: DateTime.utc_now(),
         tool_results: tool_results,
         api_logs: []
       }}

    {tool_call_message, tool_result_message,
     ctx.messages ++ [tool_call_message, tool_result_message]}
  end

  # Return a system-prompt warning when the LLM is nearing its
  # tool call iteration limit. At 2 rounds remaining the LLM is
  # told to plan carefully; at 1 round it is told no more tools
  # will be available. At 0 the caller (`run_with_new_client/2`)
  # makes a final call with `tools: nil`.
  defp iteration_warning(remaining) when is_integer(remaining) do
    case remaining do
      2 ->
        "You have 2 tool call rounds remaining. Plan your remaining tool use carefully."

      1 ->
        "This is your last tool call round. After this, no more tools will be available — provide your final response."

      _ ->
        nil
    end
  end

  @spec consume_new_stream(Enumerable.t(), non_neg_integer(), String.t(), pid()) ::
          {Client.accumulator(), RunResponse.t() | nil, term() | nil, map()}
  defp consume_new_stream(stream, message_index, agent_id, agent_pid) do
    consumer = %StreamConsumer{
      on_text: &broadcast_text_delta(&1, &2, message_index, agent_id, agent_pid),
      on_thinking: &forward_thinking_delta(&1, &2, agent_pid),
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

  defp forward_thinking_delta(text, sent, agent_pid) do
    send(agent_pid, {:delta_received, text, :thinking})
    sent
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
    error_msg = "Error: #{inspect(error)}"

    Logger.error("Agent #{ctx.agent_id} LLM request failed: #{error_msg}")

    # Broadcast error to all subscribers via PubSub
    Broadcasts.error(ctx.agent_id, state.message_index, error_msg)

    # Notify agent that streaming failed (similar to successful response)
    send(ctx.agent_pid, {:llm_error, error_msg})

    # Return the state so the caller's
    # `Task.Supervisor.start_child/2` body can destructure
    # `%RunState{api_log_sequences: _}`. Sequences are unchanged
    # on the failure path — no new request log was generated.
    state
  end
end
