defmodule Nest.LLM.ClientConfig do
  @moduledoc """
  Carries the per-agent LLM client configuration.

  `client` is the module that implements the `Nest.LLM.Client`
  behavior. `base_url`, `api_key`, `model`, and `receive_timeout`
  are passed to the client at call time via the opts list.

  `rewrite_late_system_messages` (default `false`) routes
  mid-conversation reminders (context-usage threshold,
  tool-call budget, compactor `[mode: compact]` suffix) through
  `User` messages with `[System notice: …]` brackets instead of
  through `System` messages. Set this on providers whose chat
  template rejects mid-conversation system messages
  (Qwen3.5/vLLM). Built and consulted by
  `Nest.Agents.Agent.ChatTurn.LateMessage.build/2`.
  """

  defstruct client: nil,
            base_url: nil,
            api_key: nil,
            model: nil,
            receive_timeout: nil,
            rewrite_late_system_messages: false

  @type t :: %__MODULE__{
          client: module() | nil,
          base_url: String.t() | nil,
          api_key: String.t() | nil,
          model: String.t() | nil,
          receive_timeout: non_neg_integer() | nil,
          rewrite_late_system_messages: boolean()
        }
end
