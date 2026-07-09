defmodule Nest.Agents.Agent.ChatTurn.ResponseHandler do
  @moduledoc """
  Response-handling logic for the ChatTurn. Extracted from
  `ChatTurn` to keep that module under the 500-line credo
  cap.

  ## Responsibilities

  - `handle/3` — entry point. Builds the `:assistant`
    message from the `RunResponse`, appends it via the
    Agent's `tool_calls_received/2` handler, dispatches the
    response by shape.
  - `dispatch_response/2` — branches by response shape:
    1. `force_finalize` is set (max-iterations
       second-chance) → finalize.
    2. Tool calls + past max iterations → synthesize
       error tool results, recurse with `force_finalize:
       true`.
    3. Tool calls within budget → post-response
       preflight; spawn the tool worker OR signal
       `:needs_compaction` so the Agent triggers a
       mid-turn compaction.
    4. Final text response → finalize.
  - `extract_tool_calls_from_parts/1` — public helper used
    by the live response path (here) and the chat-turn's
    mid-turn resume path.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer
  alias Nest.Agents.Agent.ChatTurn.APILog
  alias Nest.Agents.Agent.ChatTurn.Lifecycle
  alias Nest.Agents.Agent.ChatTurn.Messages
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Part

  @doc """
  Build the `:assistant` message from the LLM response,
  broadcast the response api_log, then dispatch by response
  shape. Returns the same `GenServer.reply/3` tuple the
  caller would normally emit — the chat turn just forwards
  it.

  `chat_turn_pid` is needed so we can route "send the
  {:iterate, from} after the synthetic-error path" back
  through the chat turn's mailbox (we can't use
  `GenServer.reply/3` from a helper module).
  """
  @spec handle(RunResponse.t(), State.t(), pid()) :: GenServer.reply()
  def handle(response, state, chat_turn_pid) do
    state = %{state | active_worker: nil, active_worker_kind: nil}

    send(state.ctx.agent_pid, {:llm_usage, response.usage})

    # Build the assistant message and broadcast it via the
    # Agent's handler — that handler stamps the index and
    # attaches any pending api_logs.
    {role, msg} = Messages.assistant(response)
    assistant_msg = {role, msg}
    send(state.ctx.agent_pid, {:tool_calls_received, assistant_msg})

    _ = APILog.response(state, state.active_message_index, response)

    dispatch_response(response, state, chat_turn_pid)
  end

  @doc """
  Public mirror of the ChatTurn's helper (used by the
  mid-turn resume path). Filters out non-ToolUse parts and
  converts each remaining `%Part.ToolUse{}` to a `ToolCall`
  with the same `id`, `name`, and `arguments`.
  """
  @spec extract_tool_calls_from_parts([Part.t()]) :: [ToolCall.t()]
  def extract_tool_calls_from_parts(parts) do
    parts
    |> Enum.filter(&match?(%Part.ToolUse{}, &1))
    |> Enum.map(fn %Part.ToolUse{id: id, name: name, arguments: arguments} ->
      %Nest.Messages.ToolCall{id: id, name: name, arguments: arguments || %{}}
    end)
  end

  # Dispatch on the response shape after the assistant message
  # has been appended. Four branches:
  #
  #   1. `force_finalize` is set (max-iterations second-chance) →
  #      finalize without doing more work.
  #   2. Tool calls + past max iterations → synthesize error
  #      tool results, recurse with `force_finalize: true`.
  #   3. Tool calls within budget → post-response preflight;
  #      either spawn the tool worker or signal
  #      `:needs_compaction` so the Agent triggers a
  #      mid-turn compaction.
  #   4. Final text response → finalize.
  defp dispatch_response(response, state, chat_turn_pid) do
    cond do
      state.force_finalize ->
        Lifecycle.finalize_turn(state)

      RunResponse.has_tool_calls?(response) and state.iteration > state.max_iterations ->
        handle_overflow_tool_calls(response, state, chat_turn_pid)

      RunResponse.has_tool_calls?(response) ->
        handle_normal_tool_calls(response, state)

      true ->
        Lifecycle.finalize_turn(state)
    end
  end

  # Past max iterations, LLM still emitted tool calls (the
  # `tools: nil` was supposed to prevent this but some
  # providers ignore it). Synthesize error tool results,
  # recurse with `force_finalize: true` so the next call
  # always finalizes regardless of what the LLM does.
  defp handle_overflow_tool_calls(response, state, chat_turn_pid) do
    tool_msg = Messages.synthetic_error_tool_results(response)
    _stamped_tool = GenServer.call(state.ctx.agent_pid, {:append_message, tool_msg})
    state = %{state | force_finalize: true}
    send(chat_turn_pid, :iterate)
    {:noreply, state}
  end

  # Normal tool call: post-response preflight on the projected
  # tool results. If executing them would push the conversation
  # past `context_limit - reserve`, exit cleanly and let the
  # Agent trigger a mid-turn compaction.
  defp handle_normal_tool_calls(response, state) do
    case post_response_preflight(response.tool_calls, state) do
      :fits ->
        Agent.ChatTurn.spawn_tool_worker(state, response.tool_calls)

      {:refuse, _reason} ->
        send(
          state.ctx.agent_pid,
          {:needs_compaction, self(), state.iteration, state.max_iterations}
        )

        {:stop, :normal, state}
    end
  end

  # Post-response preflight: would sending the projected tool results
  # push us over `(context_limit - reserve)`? Reuses `BatchSizer.preflight/2`
  # so the per-tool projection logic stays in one place. The fresh
  # messages list (post-LLM-response, pre-tool-execution) is what
  # the BatchSizer checks; the same projection the chat pipeline
  # uses at user-turn boundaries.
  #
  # `context.compact` is filtered out because it doesn't go through
  # BatchSizer at all — `ToolLoop.execute/3` handles it via the
  # GenServer round-trip. Including it here would force BatchSizer
  # to project a per-tool size it has no business computing.
  defp post_response_preflight(tool_calls, state) do
    {messages, _} = GenServer.call(state.ctx.agent_pid, :get_messages_with_cancelled)
    ctx = %{state.ctx | messages: messages}
    BatchSizer.preflight(Agent.ToolLoop.strip_context_compact(tool_calls), ctx)
  end
end
