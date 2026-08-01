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
    * `Nest.Agents.Agent.Handlers.ChatTurnHandler` — chat
      turn lifecycle events.
    * `Nest.Agents.Agent.Compaction.ResultHandler` —
      compaction completion + retry events (the
      trigger-side lives in
      `Nest.Agents.Agent.Compaction.Trigger`).
  * `Nest.Agents.Agent.Handlers.ExitHandler` —
      process exit signals.

  Context-limit resolution happens once at startup in
  `Nest.Agents.Agent.Init.initial_context_limit/1` (synchronous,
  reads the cached `Nest.Models` cache) — there is no
  mid-flight discovery event to handle here.
  """

  alias Nest.Agents.Agent.Compaction.ResultHandler
  alias Nest.Agents.Agent.Handlers.ApiLogHandler
  alias Nest.Agents.Agent.Handlers.ChatTurnHandler
  alias Nest.Agents.Agent.Handlers.ExitHandler
  alias Nest.Agents.Agent.Handlers.LLMStreamHandler

  @doc """
  Dispatch an arbitrary `handle_info/2` message. Returns
  the GenServer's reply tuple (`{:noreply, state}` or
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
      {:ok, ChatTurnHandler} -> ChatTurnHandler.handle(msg, state)
      {:ok, ApiLogHandler} -> ApiLogHandler.handle(msg, state)
      {:ok, ResultHandler} -> ResultHandler.handle(msg, state)
      {:ok, ExitHandler} -> ExitHandler.handle(msg, state)
      :no_match -> unknown(state)
    end
  end

  # Tag → sub-handler module. An unknown tag falls through to
  # the `unknown/1` catch-all.
  defp route_for({:delta_received, _, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:thinking_signature_received, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:llm_error, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:tool_calls_received, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:tool_results_received, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:llm_usage, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:chat_idle, _}), do: {:ok, ChatTurnHandler}
  defp route_for({:chat_stopped, _}), do: {:ok, ChatTurnHandler}
  defp route_for({:chat_crashed, _, _}), do: {:ok, ChatTurnHandler}
  defp route_for({:set_crossed_thresholds, _}), do: {:ok, ChatTurnHandler}
  defp route_for({:api_log, _, _}), do: {:ok, ApiLogHandler}
  defp route_for({:api_log_sequences_updated, _}), do: {:ok, ApiLogHandler}
  defp route_for({:compaction_done, _, _}), do: {:ok, ResultHandler}
  defp route_for({:compaction_failed, _, _}), do: {:ok, ResultHandler}
  defp route_for({:needs_compaction, _, _}), do: {:ok, ResultHandler}
  defp route_for(:retry_compaction), do: {:ok, ResultHandler}
  defp route_for(:compaction_loop_detected_ok), do: {:ok, ResultHandler}
  defp route_for({:EXIT, _, _}), do: {:ok, ExitHandler}

  defp route_for(_), do: :no_match

  defp unknown(state), do: {:noreply, state}
end
