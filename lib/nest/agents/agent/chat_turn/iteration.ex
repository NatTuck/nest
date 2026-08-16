defmodule Nest.Agents.Agent.ChatTurn.Iteration do
  @moduledoc """
  Per-iteration helpers for the ChatTurn's `safe_iterate/1`
  step. Extracted from `Nest.Agents.Agent.ChatTurn` to keep
  the iteration state machine under the credo complexity
  and line limits.

  The ChatTurn's iteration step has three concerns beyond
  the basic state-machine work:

    * broadcasting the "max iterations reached" notification
      when the cap is hit (so the UI can show a banner);
    * short-circuiting when the user clicked Stop during
      the previous iteration (the Agent's `cancelled` flag
      is checked via `:get_messages_with_cancelled`);
    * dispatching the LLM call — inject a context warning
      if appropriate, then spawn the HTTP worker.

  Each public helper returns either `:ok` or the GenServer
  reply tuple (`{:noreply, state}` / `{:stop, :normal, state}`)
  so the ChatTurn's `safe_iterate/1` can chain them or
  return them directly.

  ## Why no preflight here?

  The previous design ran a per-iteration preflight (Trigger A
  in `notes/extract-compaction-and-resumable-chat-turn.md`)
  that asked the Agent to compact if the message list would
  exceed `context_limit`. That has been replaced by the
  three-phase `Nest.Agents.Agent.BatchSizer`:

    * Batch preflight runs *after* tools execute, against
      their actual sizes.
    * Mid-sequence compaction is forbidden: the chat task's
      iteration loop is purely mechanical.
    * Compaction fires only at user-turn boundaries
      (`ChatPipeline.handle_chat/3`) or via LLM-driven
      `context-compact` calls.

  The "never send an LLM request whose message list
  predictably overflows" constraint is now satisfied by the
  BatchSizer's preflight + keep-or-summarize decision; this
  module just spawns the HTTP worker with the latest
  `state.chat_state.messages`.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatTurn.APILog
  alias Nest.Agents.Agent.ChatTurn.HTTPWorker
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Tokens.PreFlight

  @doc """
  Broadcast a `chat_notification` so the UI can show a
  banner ("Max tool iterations reached") when this
  iteration crosses the cap. Returns `:ok`.
  """
  @spec notify_max_iterations(State.t()) :: :ok
  def notify_max_iterations(state) do
    if state.iteration > state.max_iterations do
      Broadcasts.notification(state.ctx.space_id, state.ctx.agent_name, %{
        type: "max_iterations",
        message: "Max tool iterations reached"
      })
    end

    :ok
  end

  @doc """
  The user clicked Stop. Notify the Agent and stop the
  ChatTurn. The Agent's `chat_stopped` handler does the
  actual finalization (it has the current `streaming_acc`
  accumulator). Returns `{:stop, :normal, state}`.
  """
  @spec finalize_cancelled(State.t()) :: {:stop, :normal, State.t()}
  def finalize_cancelled(state) do
    send(state.ctx.agent_pid, {:chat_stopped, self()})
    {:stop, :normal, state}
  end

  @doc """
  Spawn the HTTP worker with the current `messages` list.
  Context warnings are checked at message-construction
  boundaries (ChatPipeline for user messages,
  handle_tool_results for tool responses), not here.
  """
  @spec dispatch_batch(State.t(), list()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  def dispatch_batch(state, messages) do
    spawn_http_worker(state, messages)
  end

  @doc """
  Compactor's own chat turn: dispatch the LLM call with
  `tools: nil, tool_choice: :none` (no tool calls in a
  summarization request). No context-warning injection
  (this is a one-shot call, not a long conversation),
  no budget reminder (iteration cap is irrelevant). The
  HTTP worker streams the response, the ChatTurn routes
  deltas to the Agent (via `:delta_received`), and the
  `ResponseHandler.handle/3` path appends the assistant
  message via the canonical `__append_message__/2` path.
  On `chat_idle`, `finalize_compaction/1` sends
  `{:compaction_done, summary_text, carried_entry}` to
  the Agent instead of the normal `{:chat_idle, _}`.

  The request log is queued at the suffix's index (the
  message that triggered this LLM call). The Agent's
  `api_log_handler` re-broadcasts the suffix with the
  request log attached (it already exists in the
  messages list).

  Two exceptions to "messages don't change" apply
  here (same as the previous compactor's private LLM
  call):

    1. Strip everything from the first `[mode: compact]`
       system message forward (on retry, exclude prior
       failed attempts from the LLM call's input — they
       stay in `state.chat_state.messages` for the user
       to inspect in the chat UI).
    2. Drop trailing unsatisfied tool calls (orphan
       `Part.ToolUse` — Anthropic rejects unpaired
       `tool_use` with `(2013) tool call result does not
       follow tool call`). The orphan stays in
       `state.chat_state.messages`; the next chat turn
       re-sends it with the eventual `tool_result`.
  """
  @spec dispatch_compaction(State.t(), list()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  def dispatch_compaction(state, messages) do
    state = %{state | ctx: %{state.ctx | tools: nil, tool_choice: :none}}

    {suffix, messages_without_suffix} = pop_compaction_suffix_from_end(messages)

    messages =
      messages_without_suffix
      |> strip_prior_compaction_attempts()
      |> MessageList.drop_trailing_unpaired_tool_call()
      |> build_compaction_request(suffix)

    spawn_http_worker(state, messages)
  end

  # Build the compactor's LLM request. If the last wire role
  # before the suffix is `:user`, prepend a synthetic assistant
  # bridge so the suffix (a `{:user, _}`) maintains valid
  # `assistant → user` alternation. The bridge is request-only
  # (visible in the compactor's API log, not the Agent's messages).
  defp build_compaction_request(messages, suffix) do
    messages =
      if MessageList.last_wire_role(messages) == :user do
        messages ++ [synthetic_assistant_bridge()]
      else
        messages
      end

    if suffix, do: messages ++ [suffix], else: messages
  end

  defp synthetic_assistant_bridge do
    {:assistant,
     %Assistant{
       parts: [%Part.Text{text: "Let me pause to summarize."}],
       timestamp: DateTime.utc_now(),
       api_logs: []
     }}
  end

  # Pop the compaction suffix (a message whose text starts with
  # `[mode: compact]`) from the end of the messages list. Returns
  # `{suffix, rest}` or `{nil, messages}` if not found.
  defp pop_compaction_suffix_from_end(messages) do
    rev = Enum.reverse(messages)

    case Enum.find_index(rev, &compaction_suffix_message?/1) do
      nil ->
        {nil, messages}

      idx_from_end ->
        remove_idx = length(messages) - 1 - idx_from_end
        {Enum.at(messages, remove_idx), List.delete_at(messages, remove_idx)}
    end
  end

  defp compaction_suffix_message?({:system, %Nest.Messages.System{parts: parts}}),
    do: compaction_suffix?(parts)

  defp compaction_suffix_message?({:user, %Nest.Messages.User{parts: parts}}),
    do: compaction_suffix?(parts)

  defp compaction_suffix_message?(_), do: false

  defp compaction_suffix?(parts) do
    Enum.any?(parts, fn
      %Part.Text{text: text} -> String.starts_with?(text, "[mode: compact]")
      _ -> false
    end)
  end

  defp first_compaction_suffix_index(messages) do
    Enum.find_index(messages, fn
      {:system, %Nest.Messages.System{parts: parts}} -> compaction_suffix?(parts)
      {:user, %Nest.Messages.User{parts: parts}} -> compaction_suffix?(parts)
      _ -> false
    end)
  end

  # Strip everything from the first `[mode: compact]`
  # message forward. On retry, exclude prior failed
  # compaction attempts from the LLM call's input.
  defp strip_prior_compaction_attempts(messages) do
    case first_compaction_suffix_index(messages) do
      nil -> messages
      idx -> Enum.take(messages, idx)
    end
  end

  # Spawn the HTTP worker as a Task under
  # `Nest.Agents.TaskSupervisor`. The worker calls
  # `Nest.LLM.Runner.request/2` with the given `messages`
  # and sends `{:http_response, response}` or
  # `{:http_error, error}` back to the ChatTurn.
  #
  # Choke point: every LLM request must carry a known, positive
  # `context_limit` (resolved eagerly at agent init, never nil)
  # AND the message list must have "passed" the pre-flight
  # decision — `PreFlight.ensure_passed!/2` raises if the list
  # is `:cannot_compact`, so a request is never sent from a
  # conversation where compaction is impossible.
  #
  # When we've hit the iteration cap, the next call is
  # the "final" call: `tools: nil, tool_choice: :none` so
  # the LLM sees the tool results and produces a text
  # response. The MockClient honors `tools: nil` by
  # skipping any queued tool responses and returning the
  # next text response.
  defp spawn_http_worker(%{ctx: %{context_limit: limit}} = state, messages)
       when is_integer(limit) and limit > 0 do
    PreFlight.ensure_passed!(messages, limit)
    parent = self()
    agent_pid = state.ctx.agent_pid

    # The request log is queued at the last message's
    # index (the message that triggered this LLM call:
    # the user message on a fresh turn, the tool message
    # on a continuation). The Agent's `api_log_handler`
    # will re-broadcast that message with the request log
    # attached (the message already exists in the
    # messages list, so the append-to-existing-message
    # path fires).
    request_log_index = last_message_index_for_request_log(messages)
    :ok = APILog.request(state, request_log_index, messages)

    {tools, tool_choice} = tool_config_for_iteration(state)
    state = %{state | ctx: %{state.ctx | tools: tools, tool_choice: tool_choice}}

    start_worker_task(state, parent, agent_pid, messages)
  end

  # At/over the iteration cap, the next call is the "final"
  # call: `tools: nil, tool_choice: :none` so the LLM sees the
  # tool results and produces a text response. The MockClient
  # honors `tools: nil` by skipping any queued tool responses
  # and returning the next text response.
  defp tool_config_for_iteration(state) do
    if state.iteration > state.max_iterations,
      do: {nil, :none},
      else: {state.ctx.tools, state.ctx.tool_choice}
  end

  # Spawn the HTTP worker under `Nest.Agents.TaskSupervisor`
  # and monitor it. The worker calls `Nest.LLM.Runner.request/2`
  # with the given `messages` and sends `{:http_response, ...}`
  # or `{:http_error, ...}` back to the ChatTurn.
  defp start_worker_task(state, parent, agent_pid, messages) do
    case Task.Supervisor.start_child(
           Nest.Agents.TaskSupervisor,
           fn -> HTTPWorker.run(state, parent, messages) end
         ) do
      {:ok, pid} ->
        Process.monitor(pid)
        {:noreply, %{state | active_worker: pid, active_worker_kind: :http}}

      _ ->
        # Saturated supervisor. Send a crash to the Agent
        # and stop cleanly.
        send(agent_pid, {:chat_crashed, :saturated, []})
        {:stop, :normal, state}
    end
  end

  # Return the index of the last message in the messages
  # list. The request api_log is queued at this index so
  # the message that triggered this LLM call (the user
  # message on a fresh turn, the tool message on a
  # continuation) is re-broadcast with the request log
  # attached.
  defp last_message_index_for_request_log([]), do: 0

  defp last_message_index_for_request_log(messages) do
    case List.last(messages) do
      nil -> 0
      {_, %{index: idx}} -> idx
      _ -> 0
    end
  end
end
