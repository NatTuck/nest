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
  alias Nest.LLM.Client
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.Tools, as: LLMTools
  alias Nest.Tokens.BudgetPlanner
  alias Nest.Messages.Assistant
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolResult
  alias Nest.Tokens.Estimator

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
    case run_preflight(ctx) do
      {:compacted, new_messages} ->
        run_with_new_client(%{ctx | messages: new_messages}, state)

      :proceed ->
        Logger.info("Agent #{ctx.agent_id} sending LLM request (message #{state.message_index})")
        state = broadcast_request_log(ctx, state)
        {:ok, stream} = run_request(ctx)
        handle_new_stream(ctx, state, stream)
    end
  end

  # Asks the GenServer to run a pre-flight check on its current
  # state.chat_state.messages. Returns `:proceed` if the next LLM call fits
  # (or no limit is known / a stream is in progress) and
  # `{:compacted, new_messages}` if the compactor ran. The chat
  # task blocks here on a `receive`, mirroring the
  # `compact_context` tool's round-trip pattern.
  defp run_preflight(ctx) do
    send(ctx.agent_pid, {:preflight_request, self(), ctx.messages})

    receive do
      {:preflight_result, :proceed, _messages} ->
        :proceed

      {:preflight_result, :compacted, new_messages} ->
        {:compacted, new_messages}
    after
      30_000 ->
        Logger.warning("Pre-flight request timed out; proceeding with existing messages")
        :proceed
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

  defp handle_new_stream(ctx, state, stream) do
    {_acc, response, error, _sent} =
      consume_new_stream(stream, state.message_index, ctx.agent_id, ctx.agent_pid)

    if error do
      handle_failed_response(state, error, ctx)
    else
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

    run_with_new_client(%{ctx | messages: updated_messages}, next_state)
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
      run_tool_budget_loop(
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

  # Runs the per-tool budget loop, returning a list of `ToolResult`
  # structs in the same order as the input `tool_calls`.
  #
  # The executor callback returns `{result_string, tool_default_max}`.
  # `BudgetPlanner` uses the default to enforce the per-tool cap; the
  # LLM can override it on a per-call basis via
  # `max_result_tokens` in the call's arguments (read directly by
  # the planner).
  defp run_tool_budget_loop(ctx, _state, tool_calls) do
    budget_remaining = compute_remaining_budget(ctx)

    executor = build_tool_executor(ctx)

    results =
      BudgetPlanner.execute(tool_calls, executor, budget_remaining, [])

    Enum.map(results, fn {tool_call, result_string} ->
      %ToolResult{
        tool_call_id: tool_call.id,
        name: tool_call_name(tool_call),
        content: ensure_non_empty_tool_result(result_string),
        arguments: tool_call_arguments(tool_call),
        is_error: skip_response?(result_string)
      }
    end)
  end

  defp build_tool_executor(ctx) do
    fn tool_call ->
      case tool_call_name(tool_call) do
        "compact_context" ->
          # The compact_context tool needs to mutate the agent's
          # state.chat_state.messages. The chat task can't do that directly,
          # so it round-trips through the GenServer: send a
          # request, the GenServer runs the compactor, then sends
          # the result back. The chat task blocks on a receive
          # until the result arrives.
          result = request_compaction_from_task(ctx, tool_call)
          {result, 256}

        _ ->
          raw = LLMTools.execute_one(ctx.tools, tool_call, %{caps: ctx.caps})

          {content, default_max} = tool_result_for(raw, ctx, tool_call)
          {content, default_max || 8192}
      end
    end
  end

  defp tool_result_for({:ok, content}, ctx, tool_call) do
    {content, LLMTools.default_max_result_tokens(ctx.tools, tool_call_name(tool_call))}
  end

  defp tool_result_for({:error, reason}, ctx, tool_call) do
    {reason, LLMTools.default_max_result_tokens(ctx.tools, tool_call_name(tool_call))}
  end

  # Round-trip the compaction request through the GenServer. The
  # chat task sends a request, then blocks on a receive for the
  # result. The GenServer runs the compactor (in a Task) and
  # sends the new messages back. The chat task then constructs
  # a synthetic tool result for the LLM.
  defp request_compaction_from_task(ctx, tool_call) do
    agent_pid = ctx.agent_pid
    focus = get_focus_arg(tool_call)

    send(agent_pid, {:compact_context_from_task, self(), focus})

    receive do
      {:compact_context_done, new_messages} ->
        "Compacted #{state_messages_count(ctx)} messages into a summary. You now have ~#{estimate_new_working_space(new_messages, ctx.context_limit)} tokens of working space."

      {:compact_context_failed, reason} ->
        "Compaction failed: #{inspect(reason)}"
    after
      60_000 ->
        "Compaction timed out"
    end
  end

  defp get_focus_arg(tool_call) do
    case tool_call.arguments do
      %{"focus" => f} when is_binary(f) -> f
      _ -> nil
    end
  end

  # Helper for the synthetic tool result string. The "before"
  # count is whatever the chat task is using (we don't have
  # direct access here; just say "messages"). The "after" count
  # is the new length. The "working space" is the recent slice
  # after compaction.
  defp state_messages_count(ctx) do
    length(ctx.messages || [])
  end

  defp estimate_new_working_space(new_messages, context_limit) do
    case context_limit do
      nil ->
        "unknown"

      limit when is_integer(limit) ->
        # Roughly: context_limit minus the new messages size minus
        # the reserve. Just an estimate for the LLM's awareness.
        used = Estimator.estimate_messages(new_messages)
        max(0, limit - used - 8_192)
    end
  end

  # Conservative budget for the tool-result batch. The pre-flight
  # (step 5) will replace this rough estimate with the real one.
  # For now, we charge against the running history and the budget
  # is roughly `context_limit - reserve - estimated_used`. If we
  # don't know the limit, fall back to a large number so the
  # BudgetPlanner effectively passes everything through (degraded
  # behavior — better than over-aggressive truncation).
  defp compute_remaining_budget(ctx) do
    case ctx.context_limit do
      nil ->
        1_000_000

      limit when is_integer(limit) ->
        reserve = 8192
        used = Estimator.estimate_messages(ctx.messages || [])
        max(0, limit - reserve - used)
    end
  end

  defp tool_call_name(%{name: name}), do: name || "unknown"
  defp tool_call_name(_), do: "unknown"

  defp tool_call_arguments(%{arguments: args}) when is_map(args), do: args
  defp tool_call_arguments(_), do: %{}

  defp skip_response?(content) when is_binary(content) do
    String.starts_with?(content, "[skipped:")
  end

  defp skip_response?(_), do: false

  defp ensure_non_empty_tool_result(""), do: "[no output]"
  defp ensure_non_empty_tool_result(nil), do: "[no output]"
  defp ensure_non_empty_tool_result(s) when is_binary(s), do: s
  defp ensure_non_empty_tool_result(other), do: to_string(other)

  defp consume_new_stream(stream, message_index, agent_id, agent_pid) do
    {acc, response, error, sent} =
      Enum.reduce(
        stream,
        {Client.new_accumulator(), nil, nil, %{chars: 0, thinking_chars: 0}},
        fn
          {:text, text}, {acc, response, error, sent} ->
            Broadcasts.delta_text(agent_id, message_index, text, sent.chars)
            send(agent_pid, {:delta_received, text, :text})

            new_chars = sent.chars + String.length(text)
            {Client.accumulate(acc, {:text, text}), response, error, %{sent | chars: new_chars}}

          {:thinking, text}, {acc, response, error, sent} ->
            send(agent_pid, {:delta_received, text, :thinking})
            {Client.accumulate(acc, {:text, text}), response, error, sent}

          {:tool_call_start, event}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:tool_call_start, event}), response, error, sent}

          {:tool_call_delta, event}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:tool_call_delta, event}), response, error, sent}

          {:thinking_signature, sig}, {acc, response, error, sent} ->
            # Anthropic's extended thinking emits a signature that
            # must be echoed back on subsequent turns. Forward it
            # to the agent pid so it can be persisted in the
            # assistant message's metadata.
            send(agent_pid, {:thinking_signature_received, sig})
            {Client.accumulate(acc, {:thinking, sig}), response, error, sent}

          {:usage, usage}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:usage, usage}), response, error, sent}

          {:finish_reason, reason}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:finish_reason, reason}), response, error, sent}

          {:refusal, text}, {acc, response, error, sent} ->
            {Client.accumulate(acc, {:refusal, text}), response, error, sent}

          {:done, %{response: r}}, {acc, _response, error, sent} ->
            {acc, r, error, sent}

          {:error, reason}, {acc, response, _error, sent} ->
            {acc, response, reason, sent}
        end
      )

    final_response = normalize_response(response, acc)
    # `sent` carries chars-sent counters used for delta broadcasting;
    # the running total is already in `acc`'s text buffer at this point.
    _ = sent
    {acc, final_response, error, sent}
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
