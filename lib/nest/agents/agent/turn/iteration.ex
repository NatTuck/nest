defmodule Nest.Agents.Agent.Turn.Iteration do
  @moduledoc """
  Per-iteration helpers for the in-process turn driver: the max-iterations
  notification, LLM dispatch (ordinary + compaction), and worker spawning.

  Every LLM request carries a known, positive `context_limit` and must
  have passed the pre-flight decision (`PreFlight.ensure_passed!/2`).
  An ordinary turn must never send a context that would spend the
  compaction reserve; the compactor turn is exempt.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Handlers.TurnHandler
  alias Nest.Agents.Agent.ToolLoop
  alias Nest.Agents.Agent.Turn.HTTPWorker
  alias Nest.LLM.GenerationDefaults
  alias Nest.LLM.Preflight, as: WirePreflight
  alias Nest.Messages.MessageList
  alias Nest.Tokens.Budget
  alias Nest.Tokens.PreFlight

  require Logger

  @doc """
  Broadcast a `chat_notification` when this iteration crosses the cap.
  """
  @spec notify_max_iterations(Agent.t()) :: :ok
  def notify_max_iterations(state) do
    turn = state.live.machine.work

    if turn.iteration > turn.max_iterations do
      Broadcasts.notification(state.space_id, state.name, %{
        type: "max_iterations",
        message: "Max tool iterations reached"
      })
    end

    :ok
  end

  @doc """
  Spawn the HTTP worker with the current `messages` list.
  """
  @spec dispatch_batch(Agent.t(), list()) :: {:noreply, Agent.t()}
  def dispatch_batch(state, messages) do
    state = put_max_tokens(state, ordinary_max_tokens(state))
    state = refresh_ctx_messages(state, messages)
    spawn_http_worker(state, messages)
  end

  @doc """
  Compactor's own turn: dispatch the LLM call with `tools: nil,
  tool_choice: :none`. The request is the persisted active messages
  followed by the staged compaction additions.
  """
  @spec dispatch_compaction(Agent.t(), list()) :: {:noreply, Agent.t()}
  def dispatch_compaction(state, messages) do
    state = update_work(state, &%{&1 | ctx: %{&1.ctx | tools: nil, tool_choice: :none}})
    {_, staged, _} = state.live.machine.entry

    request =
      messages
      |> MessageList.drop_trailing_unpaired_tool_call()
      |> Kernel.++(staged)

    state = put_max_tokens(state, compactor_max_tokens(state, request))
    state = refresh_ctx_messages(state, request)
    spawn_http_worker(state, request)
  end

  @doc """
  The `{tools, tool_choice}` pair for the next request. At/over the cap
  this is the "final" call with `tools: nil, tool_choice: :none`.
  """
  @spec tool_config_for_iteration(Agent.t()) :: {list() | nil, :auto | :none}
  def tool_config_for_iteration(state) do
    turn = state.live.machine.work

    if turn.iteration > turn.max_iterations,
      do: {nil, :none},
      else: {turn.ctx.tools, turn.ctx.tool_choice}
  end

  @doc """
  Spawn the tool worker for a tool-call batch. The worker sends
  `{:tool_results, ref, results}` to the Agent.
  """
  @spec spawn_tool_worker(Agent.t(), [Nest.Messages.ToolCall.t()]) :: {:noreply, Agent.t()}
  def spawn_tool_worker(state, tool_calls) do
    ctx = state.live.machine.work.ctx
    ref = make_ref()
    agent_pid = ctx.agent_pid

    task =
      Task.Supervisor.start_child(
        Nest.Agents.TaskSupervisor,
        fn ->
          Process.put(:"$callers", [agent_pid])
          results = ToolLoop.execute(ctx, %{}, tool_calls)
          send(agent_pid, {:tool_results, ref, results})
        end
      )

    case task do
      {:ok, pid} ->
        Process.monitor(pid)

        {:noreply,
         update_work(
           state,
           &%{&1 | active_worker: pid, active_worker_kind: :tools, worker_ref: ref}
         )}

      _ ->
        {:noreply, TurnHandler.chat_crashed_state(%RuntimeError{message: "saturated"}, [], state)}
    end
  end

  defp put_max_tokens(state, value) do
    update_work(state, &%{&1 | ctx: Map.put(&1.ctx, :max_tokens, value)})
  end

  defp refresh_ctx_messages(state, messages) do
    update_work(state, &%{&1 | ctx: %{&1.ctx | messages: messages}})
  end

  defp ordinary_max_tokens(state) do
    limit = state.live.machine.work.ctx.context_limit
    max(1, min(sane_default(state), round(0.20 * limit)))
  end

  defp compactor_max_tokens(state, input) do
    limit = state.live.machine.work.ctx.context_limit
    max(1, min(limit - Budget.size(input), sane_default(state)))
  end

  defp sane_default(state) do
    model = state.live.machine.work.ctx.client_config.model
    GenerationDefaults.default_max_tokens(model) || 32_000
  end

  defp spawn_http_worker(state, messages) do
    limit = state.live.machine.work.ctx.context_limit

    if is_integer(limit) and limit > 0 do
      PreFlight.ensure_passed!(messages, limit)

      if ordinary_turn?(state) and not Budget.fits?(messages, limit) do
        refuse_over_budget(state, messages, limit)
      else
        validate_and_dispatch(state, messages)
      end
    else
      refuse_invalid_sequence(state, "context_limit is not a positive integer")
    end
  end

  defp validate_and_dispatch(state, messages) do
    case WirePreflight.validate(messages) do
      :ok ->
        dispatch_http_worker(state, messages)

      {:error, violations} ->
        refuse_invalid_sequence(state, WirePreflight.format_violations(violations))
    end
  end

  defp ordinary_turn?(state), do: not match?({:compaction, _, _}, state.live.machine.entry)

  defp refuse_over_budget(state, messages, limit) do
    size = Budget.size(messages)

    message =
      "refusing to send an over-budget LLM request: " <>
        "size=#{size} + reserve > context_limit=#{limit}"

    Logger.error(message)

    {:noreply, TurnHandler.chat_crashed_state(%RuntimeError{message: message}, [], state)}
  end

  defp refuse_invalid_sequence(state, reason) do
    message = "refusing to send an invalid LLM request: #{reason}"
    Logger.error(message)

    {:noreply, TurnHandler.chat_crashed_state(%RuntimeError{message: message}, [], state)}
  end

  defp dispatch_http_worker(state, messages) do
    {tools, tool_choice} = tool_config_for_iteration(state)

    state =
      update_work(
        state,
        &%{&1 | ctx: %{&1.ctx | tools: tools, tool_choice: tool_choice, messages: messages}}
      )

    start_http_worker(state)
  end

  defp start_http_worker(state) do
    ctx = state.live.machine.work.ctx
    ref = make_ref()
    agent_pid = ctx.agent_pid

    case Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
           Process.put(:"$callers", [agent_pid])
           HTTPWorker.run(ctx, ref)
         end) do
      {:ok, pid} ->
        Process.monitor(pid)

        {:noreply,
         update_work(
           state,
           &%{&1 | active_worker: pid, active_worker_kind: :http, worker_ref: ref}
         )}

      _ ->
        {:noreply, TurnHandler.chat_crashed_state(%RuntimeError{message: "saturated"}, [], state)}
    end
  end

  defp update_work(state, fun) do
    machine = state.live.machine
    %{state | live: %{state.live | machine: %{machine | work: fun.(machine.work)}}}
  end
end
