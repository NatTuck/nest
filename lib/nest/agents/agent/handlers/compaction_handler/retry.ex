defmodule Nest.Agents.Agent.Handlers.CompactionHandler.Retry do
  @moduledoc """
  Compaction retry handling. Extracted from
  `Nest.Agents.Agent.Handlers.CompactionHandler` so that module
  stays under credo's 500-line cap.

  `retry_compaction/1` re-spawns the compactor from
  `:compaction_failed` status. It branches on whether the failed
  compaction was Trigger B (user-turn boundary,
  `pending_user_message` is set) or mid-turn
  (`mid_turn_compaction.continuation` is set). Both paths route
  through the compactor and re-use the same continuation shape as
  the original; the resulting chat turn is what differs.

  Guard: only valid when the agent is in `:compaction_failed`
  status. If the agent is in any other state (idle, streaming,
  compacting), this is a no-op — the retry is meaningless outside
  of a failed-compaction context.
  """

  require Logger

  alias Nest.Agents.Agent.Handlers.CompactionHandler
  alias Nest.Messages.Part
  alias Nest.Messages.User

  def retry_compaction(state) do
    cond do
      state.chat_state.status != :compaction_failed ->
        Logger.warning(
          "retry_compaction ignored: agent=#{state.name} status=#{inspect(state.chat_state.status)} (expected :compaction_failed)"
        )

        {:noreply, state}

      mid_turn_info = state.chat_state.mid_turn_compaction ->
        # Mid-turn retry: re-spawn the compactor with the
        # preserved continuation payload. `needs_compaction/2`
        # checks `check_consecutive/1` again and broadcasts
        # accordingly.
        CompactionHandler.needs_compaction(mid_turn_info.continuation, %{
          state
          | chat_state: %{state.chat_state | mid_turn_compaction: nil}
        })

      true ->
        # Trigger B retry: user message is held in
        # pending_user_message; on success, the compactor's
        # `:user_message` continuation appends it via
        # `append_continuation_tail/2`.
        pending = state.chat_state.pending_user_message

        case pending do
          nil ->
            Logger.warning("retry_compaction: no pending user message; agent=#{state.name}")

            {:noreply, state}

          {content, effective_mode} ->
            user_msg = {:user_message, build_stamped_user_message(content, effective_mode)}

            state = %{
              state
              | chat_state: %{
                  state.chat_state
                  | mid_turn_compaction: %{continuation: user_msg}
                }
            }

            CompactionHandler.needs_compaction(user_msg, state)
        end
    end
  end

  # Build the user message struct for retry. Mirrors
  # `ChatPipeline.build_user_message/3` but operates on already-
  # settled `pending_user_message` (the retry path runs after
  # the field is set by `handle_chat/3`). The Agent stamps the
  # index via `__append_message__/2`; we leave `index: nil`.
  defp build_stamped_user_message(content, effective_mode) do
    %User{
      index: nil,
      timestamp: DateTime.utc_now(),
      parts: [%Part.Text{text: "[mode: #{effective_mode}]\n#{content}"}],
      metadata: %{"mode" => effective_mode},
      api_logs: []
    }
  end
end
