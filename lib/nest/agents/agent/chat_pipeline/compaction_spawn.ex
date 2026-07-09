defmodule Nest.Agents.Agent.ChatPipeline.CompactionSpawn do
  @moduledoc """
  Helpers for spawning compactor tasks from the chat pipeline.

  Owns:

    * `spawn_compaction!/6` — compute the compactor's summary
      budget (`Nest.Tokens.Compactor.compute_summary_budget/4`)
      and spawn the compactor with the rendered suffix message.
    * `overflow_message/1` — the user-facing `chat:error`
      string for a context overflow.

  These were extracted from `Nest.Agents.Agent.ChatPipeline`
  to keep that module under credo's 500-line cap.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Compaction
  alias Nest.Tokens.Compactor, as: TokensCompactor
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.Reserve

  @doc """
  Compute the summary budget and spawn the compactor task.

  On `{:error, :reserve_exhausted}` (system + request exceed
  the LLM's response budget), surface the same context-overflow
  path as `:cannot_compact` — broadcast `chat:error` with the
  overflow message and return `:ok` so the GenServer doesn't
  crash.
  """
  @spec spawn_compaction!(
          pid(),
          Nest.Agents.Agent.t(),
          [tuple()],
          tuple() | nil,
          Nest.Agents.Agent.Compaction.continuation(),
          String.t() | nil
        ) :: :ok
  def spawn_compaction!(parent, state, messages, system_msg, continuation, optional_guidance)
      when is_list(messages) and is_pid(parent) do
    limit = state.llm_metrics.context_limit

    case system_msg do
      nil ->
        # No system message present (defensive — should never
        # happen in normal flow). Fall through to the overflow
        # path; refuse rather than fire a compactor with no
        # system to size against.
        broadcast_reserve_exhausted(state)
        :ok

      sys ->
        case TokensCompactor.compute_summary_budget(limit, sys, messages, optional_guidance) do
          {:ok, _n, rendered_suffix} ->
            Compaction.spawn(
              parent,
              state.client_config,
              limit,
              messages,
              continuation,
              rendered_suffix
            )

            :ok

          {:error, :reserve_exhausted} ->
            broadcast_reserve_exhausted(state)
            :ok
        end
    end
  end

  defp broadcast_reserve_exhausted(state) do
    Broadcasts.error(
      state.name,
      nil,
      overflow_message(state),
      "Nest.Agents.Agent.ChatPipeline.CompactionSpawn.spawn_compaction!/6"
    )
  end

  @doc """
  Build the user-facing `chat:error` string for a context
  overflow. Includes the actual numbers so the user can see
  why the conversation cannot start. When no system message
  is present (defensive — should never happen), the estimate
  falls back to the full message-list size.
  """
  @spec overflow_message(Nest.Agents.Agent.t()) :: String.t()
  def overflow_message(state) do
    limit = state.llm_metrics.context_limit

    sys_size =
      case Enum.find(state.chat_state.messages, &match?({:system, _}, &1)) do
        nil -> Estimator.estimate_messages(state.chat_state.messages)
        sys_msg -> Estimator.estimate_message(sys_msg)
      end

    "Cannot start a conversation: model context limit (#{limit}) cannot fit the system prompt (~#{sys_size} tokens) + reserved response budget (#{Reserve.response_budget(limit)} tokens). Use a model with a larger context window, or clear conversation history."
  end
end
