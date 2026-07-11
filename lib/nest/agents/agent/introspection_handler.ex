defmodule Nest.Agents.Agent.IntrospectionHandler do
  @moduledoc """
  `handle_call/3` clauses for the agent's introspection
  interface — `:get_*` calls used by tests, the supervisor,
  and the channel wrapper to read state without round-tripping
  through the channel layer.

  Extracted from `Nest.Agents.Agent` to keep that module under
  the credo 500-line cap.

  Each clause is a one-liner that reads a field from
  `state.chat_state` and returns it. The `:get_public_info`
  clause assembles the full public info map (cached Vocation
  + current state + usage totals) in one shot for the channel
  wrapper's `:get_public_info` GenServer call.

  The `:set_consecutive_compaction_count/2` and
  `:get_consecutive_compaction_count/0` clauses are test-only
  hooks for the loop-breaker counter. Production callers
  should not need them — the counter is managed internally
  by `CompactionHandler.check_consecutive/1` and resets via
  the append_message path in the agent's `handle_call/3`.
  """

  alias Nest.Agents.Agent
  alias Nest.Tokens.ConversationSize
  alias Nest.Vocations

  @doc """
  Dispatch an introspection `handle_call/3` message. Returns
  the GenServer's reply tuple.
  """
  @spec handle(term(), GenServer.from(), Agent.t()) :: GenServer.reply()
  def handle({:set_consecutive_compaction_count, n}, _from, state) when is_integer(n) do
    {:reply, :ok, %{state | chat_state: %{state.chat_state | consecutive_compaction_count: n}}}
  end

  def handle(:get_consecutive_compaction_count, _from, state) do
    {:reply, state.chat_state.consecutive_compaction_count, state}
  end

  def handle(:get_public_info, _from, state) do
    build_public_info(state)
  end

  def handle(:get_messages, _from, state) do
    {:reply, state.chat_state.messages, state}
  end

  # Returns `{messages, cancelled}` so the ChatTurn can
  # short-circuit on user-initiated stops without waiting
  # for the next `:stop_chat` message to be processed.
  def handle(:get_messages_with_cancelled, _from, state) do
    {:reply, {state.chat_state.messages, state.chat_state.cancelled}, state}
  end

  def handle(:get_next_index, _from, state) do
    {:reply, state.chat_state.next_message_index, state}
  end

  def handle(:get_history, _from, state) do
    {:reply, state.chat_state.history || [], state}
  end

  # Test-only introspection: returns the assembled system
  # prompt (the content of the `{:system, _}` message at
  # position 0 of `state.chat_state.messages`).
  def handle(:get_system_prompt, _from, state) do
    {:reply, system_prompt_from_messages(state.chat_state.messages), state}
  end

  def handle(:get_chat_turn_pid, _from, state) do
    {:reply, state.chat_state.chat_turn_pid, state}
  end

  # Use the cached Vocation struct from state — no DB work
  # in the handler. The struct was loaded by the calling
  # process and passed into init/1 via `:vocation` in attrs.
  defp build_public_info(state) do
    vocation = state.vocation

    public_info = %{
      name: state.name,
      model: state.model,
      message_count: length(state.chat_state.messages),
      status: state.chat_state.status,
      vocation_id: state.vocation_id,
      tmp_path: state.tmp_path,
      partial: state.chat_state.streaming_acc,
      modes: Vocations.list_modes(vocation),
      default_mode: Vocations.default_mode(vocation),
      current_mode: state.mode,
      context_limit: state.llm_metrics.context_limit,
      context_limit_source: state.llm_metrics.context_limit_source,
      usage:
        Map.put(
          state.llm_metrics.usage_totals,
          :context_input_tokens,
          ConversationSize.size(state.chat_state.messages)
        )
    }

    {:reply, public_info, state}
  end

  defp system_prompt_from_messages([{:system, %{parts: parts}} | _]) when is_list(parts) do
    parts
    |> Enum.filter(&match?(%Nest.Messages.Part.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  defp system_prompt_from_messages(_), do: nil
end
