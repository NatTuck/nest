defmodule Nest.Agents.Agent.Handlers.LLMStreamHandler do
  @moduledoc """
  `handle_info/2` handlers for LLM streaming events:
  `{:delta_received, _}`, `{:thinking_signature_received, _}`, and
  `{:llm_usage, _}`.

  Streaming touches only the in-flight accumulator and broadcasts from
  the Agent (not the HTTP worker) so subscribers always observe the
  accumulator updated. Turn decisions and turn effects live in
  `Machine.step/2` / `Turn.Executor`; the pure usage-merge helper here is
  shared with the executor's `:merge_metrics` action.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Messages.Streaming

  @doc """
  Dispatch a streaming message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:delta_received, content, part_type}, state) do
    delta_received(content, part_type, state)
  end

  def handle({:thinking_signature_received, sig}, state) do
    thinking_signature_received(sig, state)
  end

  def handle({:llm_usage, usage}, state) do
    {:noreply, llm_usage_state(usage, state)}
  end

  defp delta_received(delta_content, :text, state) do
    acc = state.live.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      chars_start = acc.chars_sent
      new_acc = Streaming.append_text(acc, delta_content)
      Broadcasts.delta_text(state.space_id, state.name, new_acc.index, delta_content, chars_start)
      {:noreply, %{state | live: %{state.live | streaming_acc: new_acc}}}
    end
  end

  defp delta_received(delta_content, :thinking, state) do
    acc = state.live.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      chars_start = acc.chars_sent
      new_acc = Streaming.append_thinking(acc, delta_content)

      Broadcasts.delta_thinking(
        state.space_id,
        state.name,
        new_acc.index,
        delta_content,
        chars_start
      )

      {:noreply, %{state | live: %{state.live | streaming_acc: new_acc}}}
    end
  end

  defp delta_received(%{id: id, name: name} = event, :tool_use_start, state) do
    acc = state.live.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      index = Map.get(event, :index, 0)

      new_tool_index_map =
        if is_binary(id),
          do: Map.put(state.live.tool_index_map, index, id),
          else: state.live.tool_index_map

      new_acc = Streaming.start_tool_call(acc, id, name)

      Broadcasts.delta_tool_use_start(state.space_id, state.name, acc.index, id, name, index)

      {:noreply,
       %{state | live: %{state.live | tool_index_map: new_tool_index_map, streaming_acc: new_acc}}}
    end
  end

  defp delta_received(%{id: id, arguments_delta: fragment} = event, :tool_use_delta, state) do
    acc = state.live.streaming_acc

    if acc == nil do
      {:noreply, state}
    else
      index = Map.get(event, :index, 0)
      concrete_id = resolve_tool_call_id(id, index, state.live.tool_index_map)

      if concrete_id do
        Broadcasts.delta_tool_use_delta(
          state.space_id,
          state.name,
          acc.index,
          concrete_id,
          index,
          fragment
        )

        new_acc = Streaming.append_tool_call_args(acc, concrete_id, fragment)
        {:noreply, %{state | live: %{state.live | streaming_acc: new_acc}}}
      else
        {:noreply, state}
      end
    end
  end

  defp delta_received(delta_content, _part_type, state) do
    delta_received(delta_content, :text, state)
  end

  defp resolve_tool_call_id(id, _index, _map) when is_binary(id), do: id
  defp resolve_tool_call_id(:by_index, index, map), do: Map.get(map, index)
  defp resolve_tool_call_id(_other, _index, _map), do: nil

  defp thinking_signature_received(signature, state) do
    new_acc = %{state.live.streaming_acc | thinking_signature: signature}
    {:noreply, %{state | live: %{state.live | streaming_acc: new_acc}}}
  end

  @doc false
  @spec llm_usage_state(map() | nil, Nest.Agents.Agent.t()) :: Nest.Agents.Agent.t()
  def llm_usage_state(usage, state) do
    state = %{
      state
      | llm_metrics: %{
          state.llm_metrics
          | usage_totals: Broadcasts.merge_usage_totals(state.llm_metrics.usage_totals, usage)
        }
    }

    Broadcasts.status(state)
    state
  end
end
