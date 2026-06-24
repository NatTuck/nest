defmodule Nest.Agents.Agent.LLMRunner do
  @moduledoc """
  Iteration coordinator for the LLM call chain. Drives the
  loop that calls the provider, executes tool calls,
  enforces the iteration cap, and reports back to the Agent
  via the canonical message tags (`:tool_calls_received`,
  `:tool_results_received`, `:llm_response_with_thinking`,
  `:llm_usage`, `:llm_error`).

  After PR 2 the heavy lifting moves to two collaborators:

    * `Nest.LLM.Runner` — the stateless HTTP client.
      Knows how to talk to the provider, knows nothing
      about iteration or tool execution.
    * `Nest.Agents.Agent.ChatTurn.Helpers` — pure message
      builders. The `(tool_call, tool_result)` pair
      construction and the budget-warning injection.

  The iteration state lives in `RunState`; the request
  context (messages, tools, agent pid) lives in
  `RunContext`. Both are local to the chat task (no
  GenServer); they're constructed by the chat pipeline and
  threaded through the iteration.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatTurn.Helpers
  alias Nest.LLM.Runner, as: LLMRunnerClient
  alias Nest.LLM.RunResponse

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

  @doc """
  Runs the LLM call chain. Returns the updated `RunState`
  with `api_log_sequences` reflecting the new request /
  response log IDs.
  """
  @spec run(RunContext.t(), RunState.t()) :: RunState.t()
  def run(%RunContext{} = ctx, %RunState{} = state), do: run_with_new_client(ctx, state)

  # New client path. Consumes the canonical event stream,
  # drives the accumulator via the GenServer's handle_info,
  # and recursively handles tool calls until the LLM
  # returns a final response or the iteration cap is hit.
  defp run_with_new_client(%RunContext{} = ctx, %RunState{max_iterations: 0} = state) do
    Logger.warning(
      "Agent #{ctx.agent_id} reached max tool iterations, making final call without tools"
    )

    Broadcasts.notification(ctx.agent_id, %{
      type: "max_iterations",
      message: "Max tool iterations reached"
    })

    # Make one final LLM call with tools disabled (both
    # tools and tool_choice) so the LLM sees the tool
    # results and produces a text response.
    final_ctx = %{ctx | tools: nil, tool_choice: :none}

    state = broadcast_request_log(final_ctx, state)
    response = run_request(final_ctx, state)
    handle_new_response(final_ctx, state, response)
  end

  defp run_with_new_client(%RunContext{} = ctx, %RunState{} = state) do
    case run_preflight(ctx) do
      {:compacted, new_messages} ->
        run_with_new_client(%{ctx | messages: new_messages}, state)

      {:proceed, messages} ->
        ctx = %{ctx | messages: messages}
        Logger.info("Agent #{ctx.agent_id} sending LLM request (message #{state.message_index})")
        state = broadcast_request_log(ctx, state)
        response = run_request(ctx, state)
        handle_new_response(ctx, state, response)

      :stopped ->
        raise Nest.Agents.Agent.ToolLoop.StoppedError
    end
  end

  # Asks the GenServer to run a pre-flight check. Returns
  # `:proceed`, `{:compacted, new_messages}`, or `:stopped`
  # if the user interrupted.
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
    request = LLMRunnerClient.build_request(ctx)
    opts = LLMRunnerClient.build_opts(ctx)

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

  # Make a single HTTP call and return the response. The
  # callbacks handle delta broadcasting, signature
  # forwarding, and the cooperative stop check.
  #
  # The `message_index` for delta broadcasts comes from
  # `state.message_index` (the LLMRunner's predicted
  # response index, set from the Agent's `streaming_acc.index`
  # at the start of the iteration and bumped by `+ 2`
  # after each tool pair).
  defp run_request(ctx, state) do
    callbacks = build_request_callbacks(ctx, state.message_index)
    LLMRunnerClient.request(ctx, callbacks) |> handle_request_outcome()
  end

  defp build_request_callbacks(ctx, message_index) do
    %{
      on_text: text_delta_callback(ctx.agent_id, ctx.agent_pid, message_index, :text),
      on_thinking: text_delta_callback(ctx.agent_id, ctx.agent_pid, message_index, :thinking),
      on_signature: fn signature ->
        send(ctx.agent_pid, {:thinking_signature_received, signature})
      end,
      on_error: fn error ->
        broadcast_request_error(ctx.agent_id, ctx.agent_pid, message_index, error)
      end,
      on_response: fn _response -> :ok end,
      should_stop: &check_should_stop/0
    }
  end

  defp text_delta_callback(agent_id, agent_pid, message_index, part_type) do
    delta_broadcaster =
      case part_type do
        :text -> &LLMRunnerClient.delta_text/4
        :thinking -> &LLMRunnerClient.delta_thinking/4
      end

    fn text, sent ->
      delta_broadcaster.(agent_id, message_index, text, sent.chars)
      send(agent_pid, {:delta_received, text, part_type})
      %{sent | chars: sent.chars + String.length(text)}
    end
  end

  defp broadcast_request_error(agent_id, agent_pid, message_index, error) do
    error_msg = LLMRunnerClient.format_error(error)

    # `Broadcasts.error/4` is the centralized error path:
    # it logs the failure (with agent_id, message_index,
    # and source) and broadcasts the `chat:error` event
    # with a `[Source: ...]` tag so the UI shows where
    # the error originated. The source string keeps the
    # original `LLMRunner.handle_failed_response/3` name
    # so existing log greps and tests still match.
    Broadcasts.error(
      agent_id,
      message_index,
      error_msg,
      "LLMRunner.handle_failed_response/3"
    )

    send(agent_pid, {:llm_error, error_msg})
  end

  # Non-blocking mailbox check for a `{:stop_chat, _}`
  # message. Returns `true` if the chat task should halt
  # the current stream iteration. The `after 0` yields to
  # the scheduler so the agent's
  # `handle_info({:stop_chat, _}, state)` can run between
  # events and deliver the stop to the chat task's
  # mailbox.
  defp check_should_stop do
    receive do
      {:stop_chat, from} ->
        send(from, :stopped)
        true
    after
      0 -> false
    end
  end

  defp handle_request_outcome({:ok, %RunResponse{} = response}), do: response

  # Stream halted cooperatively (user clicked Stop
  # mid-stream). The `should_stop/0` callback already
  # replied `:stopped` to the Agent. Raise
  # `ToolLoop.StoppedError` so the chat task body
  # catches it and sends `{:chat_stopped, self()}`
  # back to the Agent — that's the Agent's stop
  # handler's signal to finalize the partial.
  defp handle_request_outcome({:ok, nil}) do
    raise Nest.Agents.Agent.ToolLoop.StoppedError
  end

  # The `on_error/1` callback already broadcast
  # `chat:error` and sent `{:llm_error, _}` to the
  # Agent. Return `:error` and let
  # `handle_new_response/3` exit the iteration without
  # making more LLM calls.
  defp handle_request_outcome({:error, _reason}), do: :error

  # Dispatch on the response: error → log and stop; tool
  # calls → execute and recurse; final text → notify and
  # return.
  defp handle_new_response(ctx, state, %RunResponse{} = response) do
    sequences =
      broadcast_new_response_log(
        ctx.agent_pid,
        state.message_index,
        state.api_log_sequences,
        response
      )

    state = %{state | api_log_sequences: sequences}

    # Forward usage to the GenServer so the running totals
    # update and the next chat:status push carries the
    # fresh numbers. `usage` is `nil` for clients that
    # don't populate it; the merge helper treats nil as a
    # no-op.
    send(ctx.agent_pid, {:llm_usage, response.usage})

    cond do
      state.force_finalize ->
        # Second-chance call after max-iterations: force-
        # finalize regardless of what the LLM returned, so
        # we don't loop forever if it ignores
        # `tool_choice: :none` again.
        send_final_assistant(ctx, state, response)

      state.max_iterations <= 0 and RunResponse.has_tool_calls?(response) ->
        handle_max_iterations_with_tool_calls(ctx, state, response)

      RunResponse.has_tool_calls?(response) ->
        run_with_new_client_after_tool_calls(ctx, state, response)

      true ->
        send_final_assistant(ctx, state, response)
    end
  end

  # The runner returned `:error` (Consumer's `on_error`
  # already broadcast `chat:error` and sent `{:llm_error,
  # _}` to the Agent). Exit the iteration without making
  # more LLM calls. The `:stopped` case is raised as
  # `ToolLoop.StoppedError` from `run_request/2` and
  # caught by the chat task body.
  defp handle_new_response(_ctx, state, :error), do: state

  defp send_final_assistant(ctx, state, response) do
    send(ctx.agent_pid, {:llm_response_with_thinking, response, response.thinking})
    state
  end

  # The LLM hit the iteration cap and we made the final
  # call with `tools: nil, tool_choice: :none`. If the LLM
  # still emitted tool calls anyway (some providers don't
  # honor `tool_choice: :none`), give it one more chance:
  # synthesize error tool results so it sees the
  # constraint, then call again with `force_finalize: true`
  # so the second-chance text becomes the final answer no
  # matter what.
  defp handle_max_iterations_with_tool_calls(ctx, state, response) do
    Logger.warning(
      "Agent #{ctx.agent_id} LLM emitted tool calls on max-iterations " <>
        "final call; sending synthetic errors and trying once more"
    )

    {tool_call_message, tool_result_message, messages_with_synthesized} =
      Helpers.build_synthetic_error_pair(ctx, state, response)

    send(ctx.agent_pid, {:tool_calls_received, tool_call_message})
    send(ctx.agent_pid, {:tool_results_received, tool_result_message})

    # Recurse with the second-chance flag, no tools, and
    # `max_iterations: 0` (the second-chance call doesn't
    # get its own tool budget). `force_finalize: true`
    # makes `handle_new_response/3` always return the text
    # response.
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
      Helpers.build_tool_pair(ctx, state, response)

    send(ctx.agent_pid, {:tool_calls_received, tool_call_message})
    send(ctx.agent_pid, {:tool_results_received, tool_result_message})

    next_state = %RunState{
      message_index: state.message_index + 2,
      active_message_index: state.message_index + 1,
      api_log_sequences: state.api_log_sequences,
      max_iterations: state.max_iterations - 1
    }

    messages_with_reminder =
      Helpers.maybe_inject_budget_warning(
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

  defp broadcast_new_request_log(
         client_config,
         request,
         opts,
         agent_pid,
         active_message_index,
         api_log_sequences
       ) do
    payload = LLMRunnerClient.format_request_payload(client_config, request, opts)

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
end
