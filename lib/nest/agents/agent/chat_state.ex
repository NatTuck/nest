defmodule Nest.Agents.Agent.ChatState do
  @moduledoc """
  Per-agent chat operation state. Holds the live and archived
  message histories, the streaming accumulator, status, and
  API-log bookkeeping. Lives in a sub-struct so the `Agent`
  struct stays focused on identity and configuration.
  """
  defstruct messages: [],
            history: [],
            next_message_index: 0,
            streaming_acc: nil,
            status: :idle,
            active_message_index: 0,
            api_log_sequences: %{},
            pending_api_logs: %{}
end
