defmodule Nest.Agents.Agent.Handlers do
  @moduledoc """
  Top-level dispatcher for `handle_info/2` messages on the
  agent GenServer. Routes each message tag to a focused
  sub-handler module that owns the per-message logic.

  Sub-handlers:

    * `Nest.Agents.Agent.Handlers.LLMStreamHandler` — LLM
      streaming events (deltas, tool calls, tool results,
      errors, usage).
    * `Nest.Agents.Agent.Handlers.ApiLogHandler` — API log
      events.
    * `Nest.Agents.Agent.Handlers.CompactionHandler` —
      compaction and pre-flight events.
    * `Nest.Agents.Agent.Handlers.ExitHandler` — process
      exit signals.

  The context-limit event (`{:discovered_context_limit, _, _}`)
  is handled inline because it has a single, simple
  implementation that doesn't justify its own module.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Handlers.ApiLogHandler
  alias Nest.Agents.Agent.Handlers.CompactionHandler
  alias Nest.Agents.Agent.Handlers.ExitHandler
  alias Nest.Agents.Agent.Handlers.LLMStreamHandler
  alias Nest.Agents.Agent.Handlers.StopHandler

  @doc """
  Dispatch an arbitrary `handle_info/2` message. Returns the
  GenServer's reply tuple (`{:noreply, state}` or
  `{:stop, reason, state}`).

  The message tag is extracted to look up a sub-handler
  module; the sub-handler then pattern-matches the message
  shape. This keeps the top-level dispatch under the ABCSize
  and cyclomatic-complexity limits.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle(msg, state) do
    case route_for(msg) do
      {:ok, LLMStreamHandler} -> LLMStreamHandler.handle(msg, state)
      {:ok, ApiLogHandler} -> ApiLogHandler.handle(msg, state)
      {:ok, CompactionHandler} -> CompactionHandler.handle(msg, state)
      {:ok, ExitHandler} -> ExitHandler.handle(msg, state)
      {:ok, StopHandler} -> StopHandler.handle(msg, state)
      {:inline_discovered, source, limit} -> discovered_context_limit(source, limit, state)
      :no_match -> unknown(state)
    end
  end

  # Tag → sub-handler module. An unknown tag falls through to
  # the `unknown/1` catch-all. `discovered_context_limit` is
  # the one event we handle inline (single impl, no need for
  # its own module).
  defp route_for({:delta_received, _, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:thinking_signature_received, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:llm_error, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:chat_task_crashed, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:chat_task_crashed, _, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:tool_calls_received, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:tool_results_received, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:llm_response_with_thinking, _, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:llm_usage, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:api_log, _, _}), do: {:ok, ApiLogHandler}
  defp route_for({:api_log_sequences_updated, _}), do: {:ok, ApiLogHandler}
  defp route_for({:compaction_done, _, _}), do: {:ok, CompactionHandler}
  defp route_for({:task_compaction_request, _, _}), do: {:ok, CompactionHandler}
  defp route_for({:task_compaction_done, _, _}), do: {:ok, CompactionHandler}
  defp route_for({:task_compaction_failed, _, _}), do: {:ok, CompactionHandler}
  defp route_for({:preflight_request, _, _}), do: {:ok, CompactionHandler}
  defp route_for({:compaction_failed_for_preflight, _, _}), do: {:ok, CompactionHandler}
  defp route_for({:stop_chat, _}), do: {:ok, StopHandler}
  defp route_for({:chat_stopped, _}), do: {:ok, StopHandler}
  defp route_for({:EXIT, _, _}), do: {:ok, ExitHandler}

  defp route_for({:discovered_context_limit, source, limit}) do
    {:inline_discovered, source, limit}
  end

  defp route_for(_), do: :no_match

  # Update state with the discovered limit and broadcast a fresh
  # chat:status so the frontend can swap the chip's denominator from
  # the default to the real value.
  defp discovered_context_limit(source, limit, state) do
    state = %{
      state
      | llm_metrics: %{state.llm_metrics | context_limit: limit, context_limit_source: source}
    }

    Broadcasts.status(state.id, state)
    {:noreply, state}
  end

  defp unknown(state), do: {:noreply, state}
end
