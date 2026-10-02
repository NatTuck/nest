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
  alias Nest.Agents.Agent.ChatTurn.HTTPWorker
  alias Nest.Agents.Agent.ChatTurn.State
  alias Nest.LLM.GenerationDefaults
  alias Nest.LLM.Preflight, as: WirePreflight
  alias Nest.Messages.MessageList
  alias Nest.Tokens.Budget
  alias Nest.Tokens.PreFlight

  require Logger

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
    state = put_max_tokens(state, ordinary_max_tokens(state))
    spawn_http_worker(state, messages)
  end

  @doc """
  Compactor's own chat turn: dispatch the LLM call with `tools: nil,
  tool_choice: :none` (no tool calls in a summarization request). No
  context-warning injection (this is a one-shot call) and no budget
  reminder (the iteration cap is irrelevant).

  The request is the persisted active messages followed by the *staged*
  compaction additions carried in the entry (`{:compaction, staged, _}`):
  an assistant bridge when the tail wire role is a user role, plus the
  `[mode: compact]` suffix. The staged messages are NOT in
  `state.chat_state.messages`; they are persisted only when the compaction
  commits (`ResultHandler`), so a failed compaction leaves no rows and the
  persisted sequence always reflects exactly what was sent.

  Trailing unsatisfied tool calls are dropped from the request as a defense
  (Anthropic rejects an unpaired `tool_use`); with confirm-then-persist this
  should never fire on the live path.
  """
  @spec dispatch_compaction(State.t(), list()) ::
          {:noreply, State.t()} | {:stop, :normal, State.t()}
  def dispatch_compaction(state, messages) do
    state = %{state | ctx: %{state.ctx | tools: nil, tool_choice: :none}}
    {_, staged, _} = state.entry

    request =
      messages
      |> MessageList.drop_trailing_unpaired_tool_call()
      |> Kernel.++(staged)

    state = put_max_tokens(state, compactor_max_tokens(state, request))
    spawn_http_worker(state, request)
  end

  # `max_tokens` is required on the Anthropic wire (the client substitutes a
  # default). We send the lower of the conservative remaining window and the
  # model/provider default so the request is always valid and the reply can
  # use the full room without the provider rejecting the call.
  defp put_max_tokens(state, value), do: %{state | ctx: Map.put(state.ctx, :max_tokens, value)}

  defp ordinary_max_tokens(%{ctx: %{context_limit: limit}} = state) do
    max(1, min(sane_default(state), round(0.20 * limit)))
  end

  defp compactor_max_tokens(%{ctx: %{context_limit: limit}} = state, input) do
    max(1, min(limit - Budget.size(input), sane_default(state)))
  end

  defp sane_default(%{ctx: %{client_config: %{model: model}}}),
    do: GenerationDefaults.default_max_tokens(model) || 32_000

  defp sane_default(_), do: 32_000

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

    # Tripwire: an ordinary turn must never send a context that would spend
    # the compaction reserve. Reaching here means an upstream gate (deferral
    # / confirm-then-persist / synthetic accounting) is wrong. The compactor
    # turn is exempt — its input is allowed to fill the whole window (see
    # `notes/compaction-reserve-plan.md`).
    if ordinary_turn?(state) and not Budget.fits?(messages, limit) do
      refuse_over_budget(state, messages, limit)
    else
      case WirePreflight.validate(messages) do
        :ok -> dispatch_http_worker(state, messages)
        {:error, violations} -> refuse_invalid_sequence(state, violations)
      end
    end
  end

  defp ordinary_turn?(state), do: not match?({:compaction, _, _}, state.entry)

  # Never send a request whose list would spend the compaction reserve.
  # Surface the invariant violation through the Agent's crash path
  # (`chat:error`) and stop the turn.
  defp refuse_over_budget(%{ctx: %{agent_pid: agent_pid}} = state, messages, limit) do
    size = Budget.size(messages)

    exception = %RuntimeError{
      message:
        "refusing to send an over-budget LLM request: " <>
          "size=#{size} + reserve > context_limit=#{limit}"
    }

    Logger.error(exception.message)
    send(agent_pid, {:chat_crashed, exception, []})
    {:stop, :normal, state}
  end

  defp dispatch_http_worker(state, messages) do
    parent = self()
    agent_pid = state.ctx.agent_pid

    {tools, tool_choice} = tool_config_for_iteration(state)
    state = %{state | ctx: %{state.ctx | tools: tools, tool_choice: tool_choice}}

    start_worker_task(state, parent, agent_pid, messages)
  end

  # The sequence handed to the worker is invalid (an orphan `tool_use`
  # the append-time guard could not prevent — e.g. restored legacy
  # state). Never send it: surface the rule + offending ids through the
  # Agent's crash path (`chat:error`) and stop the turn. The live path
  # is repaired by `MessageAppender`; persisted corruption by the
  # offline tool (`notes/enforce-mesages-seq-invariants.md`).
  defp refuse_invalid_sequence(%{ctx: %{agent_pid: agent_pid}} = state, violations) do
    exception = %RuntimeError{message: WirePreflight.format_violations(violations)}
    send(agent_pid, {:chat_crashed, exception, []})
    {:stop, :normal, state}
  end

  @doc """
  The `{tools, tool_choice}` pair for the next request.

  At/over the iteration cap this is the "final" call: `tools: nil,
  tool_choice: :none`, so the LLM sees the tool results and produces a
  text response instead of asking for another round. Below the cap the
  turn's own tools and tool choice pass through unchanged.

  The MockClient honors `tools: nil` by skipping any queued tool
  responses and returning the next text response.
  """
  @spec tool_config_for_iteration(State.t()) :: {list() | nil, :auto | :none}
  def tool_config_for_iteration(state) do
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
end
