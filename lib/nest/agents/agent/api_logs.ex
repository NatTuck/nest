defmodule Nest.Agents.Agent.ApiLogs do
  @moduledoc false
  # Tiny module exposing the Agent's queued `pending_api_logs`
  # operations to the Handlers submodules. The canonical state
  # lives in `state.chat_state.pending_api_logs`; this module
  # exists so the Handlers code path doesn't have to depend
  # on the whole Agent module (which would be a circular
  # dependency: Handlers is a submodule of Agent).
  #
  # Extracted from `Nest.Agents.Agent` to keep that module
  # under the 500-line credo cap.

  @doc false
  def get(state, message_index) do
    Map.get(state.chat_state.pending_api_logs, message_index, [])
  end

  @doc false
  def clear(state, message_index) do
    %{
      state
      | chat_state: %{
          state.chat_state
          | pending_api_logs: Map.delete(state.chat_state.pending_api_logs, message_index)
        }
    }
  end
end
