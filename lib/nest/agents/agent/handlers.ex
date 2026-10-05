defmodule Nest.Agents.Agent.Handlers do
  @moduledoc """
  Top-level dispatcher for `handle_info/2` messages on the agent
  GenServer. Routes each message tag to a focused sub-handler module.

  Turn-machine events (worker results, iteration, stop timer, worker
  death) are translated by `Nest.Agents.Agent.Turn.handle/2` into
  `Machine.step/2` events. LLM streaming deltas stay in
  `Handlers.LLMStreamHandler` because they never touch the machine.
  """

  alias Nest.Agents.Agent.Handlers.ApiLogHandler
  alias Nest.Agents.Agent.Handlers.ExitHandler
  alias Nest.Agents.Agent.Handlers.LLMStreamHandler
  alias Nest.Agents.Agent.Turn

  @doc """
  Dispatch an arbitrary `handle_info/2` message. Returns
  the GenServer's reply tuple (`{:noreply, state}` or
  `{:stop, reason, state}`).
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle(msg, state) do
    case route_for(msg) do
      {:ok, LLMStreamHandler} -> LLMStreamHandler.handle(msg, state)
      {:ok, Turn} -> Turn.handle(msg, state)
      {:ok, ApiLogHandler} -> ApiLogHandler.handle(msg, state)
      {:ok, ExitHandler} -> ExitHandler.handle(msg, state)
      :no_match -> {:noreply, state}
    end
  end

  defp route_for({:delta_received, _, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:thinking_signature_received, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:llm_usage, _}), do: {:ok, LLMStreamHandler}
  defp route_for({:api_log_sequences_updated, _}), do: {:ok, ApiLogHandler}
  defp route_for({:EXIT, _, _}), do: {:ok, ExitHandler}

  defp route_for(:iterate), do: {:ok, Turn}
  defp route_for(:stop_timer), do: {:ok, Turn}
  defp route_for({:chat_idle, _}), do: {:ok, Turn}
  defp route_for({:chat_stopped, _}), do: {:ok, Turn}
  defp route_for({:llm_error, _}), do: {:ok, Turn}
  defp route_for({:http_response, _, _}), do: {:ok, Turn}
  defp route_for({:compaction_ok, _}), do: {:ok, Turn}
  defp route_for({:http_error, _, _}), do: {:ok, Turn}
  defp route_for({:worker_crashed, _, _, _}), do: {:ok, Turn}
  defp route_for({:tool_results, _, _}), do: {:ok, Turn}
  defp route_for({:DOWN, _, :process, _, _}), do: {:ok, Turn}

  defp route_for(_), do: :no_match
end
