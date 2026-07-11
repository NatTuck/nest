defmodule Nest.Agents.Agent.Compaction.Overflow do
  @moduledoc """
  User-facing `chat:error` for context overflow conditions.

  Two paths land here:

    * `:cannot_compact` — preflight (in
      `Nest.Agents.Agent.ChatPipeline`) decides the system
      prompt alone exceeds the model's context limit, so
      compaction would be a no-op. The chat pipeline sets
      `:context_overflow` status and rejects further
      `chat:message` traffic.

    * `:reserve_exhausted` — the compactor's summary
      budget computation (in
      `Nest.Agents.Agent.Compaction.Trigger`) finds the
      system + suffix would overflow the LLM's response
      budget. The agent stays in its current status (no
      spawn) and the user is told why compaction can't
      proceed.

  Both paths share the same message structure (model
  context limit, system prompt size in tokens, reserved
  response budget in tokens) and the same broadcast shape
  (`Broadcasts.error/4` with a `nil` index). Centralizing
  them here prevents the two paths from drifting apart
  (the pre-refactor code had three copies of the message
  and they had already diverged in tone).

  The `verb` parameter (`"start a conversation"` vs
  `"compact"`) is the only difference between the two
  paths' messages — it tells the user *what* the agent
  was trying to do when the overflow was detected.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.Reserve

  @type verb :: String.t()

  @doc """
  Build the user-facing `chat:error` string for a context
  overflow. Includes the actual numbers (limit, system
  prompt size, reserved response budget) so the user can
  see why the conversation cannot fit.

  `verb` is the action the agent was attempting when the
  overflow was detected:

    * `"start a conversation"` — the preflight refused
      the user's message before any compaction ran
      (`:cannot_compact`).
    * `"compact"` — the compactor's budget check refused
      to run (`:reserve_exhausted`).
  """
  @spec message(Nest.Agents.Agent.t(), verb()) :: String.t()
  def message(state, verb \\ "compact") do
    limit = state.llm_metrics.context_limit
    sys_size = system_size(state)

    "Cannot #{verb}: model context limit (#{limit}) cannot fit the system prompt (~#{sys_size} tokens) + reserved response budget (#{Reserve.response_budget(limit)} tokens). Use a model with a larger context window, or clear conversation history."
  end

  @doc """
  Find the system message and estimate its size in tokens.
  When no system message is present (defensive — should
  never happen in normal flow), the estimate falls back
  to the full message-list size.
  """
  @spec system_size(Nest.Agents.Agent.t()) :: non_neg_integer()
  def system_size(state) do
    case Enum.find(state.chat_state.messages, &match?({:system, _}, &1)) do
      nil -> Estimator.estimate_messages(state.chat_state.messages)
      sys_msg -> Estimator.estimate_message(sys_msg)
    end
  end

  @doc """
  Broadcast the overflow `chat:error` to the UI. The
  `source` is the call site (e.g.
  `"Nest.Agents.Agent.ChatPipeline.handle_preflight/2"` or
  `inspect(Nest.Agents.Agent.Compaction.Trigger)`) for log
  correlation.

  Does NOT change the agent's status — callers set the
  status they want (e.g. `chat_pipeline` sets
  `:context_overflow`; `trigger` leaves the status
  unchanged). The two paths have different status
  semantics and this module is the shared part, not the
  status policy.
  """
  @spec broadcast(Nest.Agents.Agent.t(), String.t(), verb()) :: :ok
  def broadcast(state, source, verb \\ "compact") do
    Broadcasts.error(
      state.name,
      nil,
      message(state, verb),
      source
    )
  end
end
