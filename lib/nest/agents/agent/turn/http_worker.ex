defmodule Nest.Agents.Agent.Turn.HTTPWorker do
  @moduledoc """
  The HTTP worker body for the in-process turn driver. Runs in a Task
  under `Nest.Agents.TaskSupervisor`. Calls `Nest.LLM.Runner.request/2`
  with streaming callbacks that re-broadcast deltas through the Agent.

  Results are sent to the Agent tagged with the turn's `worker_ref` so a
  stale/duplicate result (one that arrives after the turn was cleared by
  a stop or finalize) is dropped.
  """

  alias Nest.LLM.Runner
  alias Nest.LLM.RunResponse

  require Logger

  @doc """
  Run the HTTP call with the request in `ctx.messages`. Sends
  `{:http_response, ref, response}`, `{:http_error, ref, reason}`, or
  `{:worker_crashed, ref, exception, stacktrace}` to the Agent.
  """
  @spec run(map(), reference()) :: :ok
  def run(ctx, worker_ref) do
    callbacks = build_callbacks(ctx)
    agent_pid = ctx.agent_pid

    try do
      dispatch_result(Runner.request(ctx, callbacks), agent_pid, worker_ref)
    catch
      kind, reason ->
        forward_crash(kind, reason, __STACKTRACE__, ctx.agent_name, agent_pid, worker_ref)
    end
  end

  defp dispatch_result({:ok, %RunResponse{} = response}, agent_pid, ref) do
    send(agent_pid, {:http_response, ref, response})
  end

  defp dispatch_result({:ok, nil}, _agent_pid, _ref), do: :ok

  defp dispatch_result({:error, reason}, agent_pid, ref) do
    send(agent_pid, {:http_error, ref, reason})
  end

  defp forward_crash(kind, reason, stacktrace, agent_id, agent_pid, worker_ref) do
    if not benign_exit?(kind, reason) do
      Logger.error(fn ->
        "[agent_turn] HTTP worker CRASHED: agent_id=#{agent_id} kind=#{kind} reason=#{inspect(reason)}\n" <>
          Exception.format(kind, reason, stacktrace)
      end)
    end

    exception =
      case reason do
        %{__exception__: _} = ex -> ex
        other -> %RuntimeError{message: inspect(other)}
      end

    send(agent_pid, {:worker_crashed, worker_ref, exception, stacktrace})
    :ok
  end

  defp benign_exit?(:exit, {:normal, {GenServer, :call, _}}), do: true
  defp benign_exit?(:exit, {:noproc, {GenServer, :call, _}}), do: true
  defp benign_exit?(:exit, {:shutdown, {GenServer, :call, _}}), do: true
  defp benign_exit?(_kind, _reason), do: false

  defp build_callbacks(ctx) do
    %{
      on_text: fn text, sent ->
        send(ctx.agent_pid, {:delta_received, text, :text})
        %{sent | chars: sent.chars + String.length(text)}
      end,
      on_thinking: fn text, sent ->
        send(ctx.agent_pid, {:delta_received, text, :thinking})
        %{sent | chars: sent.chars + String.length(text)}
      end,
      on_signature: fn _sig -> :ok end,
      on_tool_call_start: fn event, sent ->
        send(ctx.agent_pid, {:delta_received, event, :tool_use_start})
        sent
      end,
      on_tool_call_delta: fn event, sent ->
        send(ctx.agent_pid, {:delta_received, event, :tool_use_delta})
        sent
      end,
      on_error: fn error ->
        error_msg = Runner.format_error(error)
        send(ctx.agent_pid, {:llm_error, error_msg})
      end,
      on_response: fn _response -> :ok end,
      should_stop: fn _acc -> check_should_stop?(ctx) end
    }
  end

  defp check_should_stop?(ctx) do
    ctx.agent_pid
    |> :sys.get_state()
    |> Map.get(:live)
    |> Map.get(:cancelled)
  catch
    :exit, _reason -> false
  end
end
