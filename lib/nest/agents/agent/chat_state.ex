defmodule Nest.Agents.Agent.ChatState do
  @moduledoc """
  Per-agent chat operation state. Holds the live and archived
  message histories, the streaming accumulator, status, and
  API-log bookkeeping. Lives in a sub-struct so the `Agent`
  struct stays focused on identity and configuration.

  The `chat_task_pid` field tracks the in-flight `Task.Supervisor`
  child that is currently driving the LLM call chain for this
  agent. It is set when the chat task is spawned (in
  `ChatPipeline.spawn_chat_task/3`) and cleared on natural
  completion or after a user-initiated stop. The stop-handler
  reads it to send a `{:stop_chat, _}` signal.

  The `cancelled` field is a sticky flag set when the user
  clicks Stop. It guards the `compaction_done` /
  `chat_continuation` branch so an in-flight compaction result
  does not auto-resume a new chat turn after the user has
  already stopped.
  """
  defstruct messages: [],
            history: [],
            next_message_index: 0,
            streaming_acc: nil,
            status: :idle,
            active_message_index: 0,
            api_log_sequences: %{},
            pending_api_logs: %{},
            chat_task_pid: nil,
            cancelled: false
end
