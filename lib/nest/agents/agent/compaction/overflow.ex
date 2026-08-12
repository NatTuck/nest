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

  ## Source of truth for the system size

  The rendered system prompt (from
  `Nest.Agents.Agent.SystemPrompt.compose_vocation_config/5`)
  is the single source of truth for the system size. Callers
  precompute it and pass it in; `Overflow` does NOT look at
  `state.chat_state.messages[0]`. This avoids the trap where
  `messages[0]` is non-system (e.g. a legacy conversation, or
  a transient state after a partial compaction swap where
  the rebuilt system was dropped) and a fallback inflated the
  size to the whole conversation.
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.Reserve

  @type verb :: String.t()
  @type reason :: :reserve_exhausted | :system_oversized

  @doc """
  Build the user-facing `chat:error` string for a context
  overflow. `reason` selects the wording:

    * `:reserve_exhausted` (default) — the compactor's
      summary budget computation found the system + suffix
      would overflow the LLM's response budget.

    * `:system_oversized` — the rendered system prompt
      exceeds the `#max_fraction_of_context` safety budget
      for the context window. Refuses to produce the
      oversized system message and surfaces the actual size
      so the user can shorten it.
  """
  @spec message(non_neg_integer(), String.t() | nil, verb(), reason()) :: String.t()
  def message(limit, system_prompt, verb \\ "compact", reason \\ :reserve_exhausted)

  def message(limit, system_prompt, verb, :reserve_exhausted)
      when is_integer(limit) and limit > 0 do
    sys_size = system_size(system_prompt)

    "Cannot #{verb}: model context limit (#{limit}) cannot fit the system prompt (~#{sys_size} tokens) + reserved response budget (#{Reserve.response_budget(limit)} tokens). Use a model with a larger context window, or clear conversation history."
  end

  def message(limit, system_prompt, verb, :system_oversized)
      when is_integer(limit) and limit > 0 do
    sys_size = system_size(system_prompt)
    budget = SystemPrompt.within_size_budget_budget(limit)

    "Cannot #{verb}: system prompt is ~#{sys_size} tokens, exceeding the 25% safety budget (~#{budget} tokens) for this #{limit}-token context window. Use a shorter system prompt or change model."
  end

  @doc """
  Estimate the token count for the rendered `system_prompt`.
  The wire-format overhead (`@per_message_overhead` from the
  Estimator) is included so the size is comparable to
  `Estimator.estimate_message/1`'s `{:system, _}` clause.

  `nil` returns `0` — no system prompt was rendered (e.g.
  the agent has no vocation).
  """
  @spec system_size(String.t() | nil) :: non_neg_integer()
  def system_size(nil), do: 0

  def system_size(system_prompt) when is_binary(system_prompt) do
    Estimator.estimate(system_prompt)
  end

  @doc """
  Broadcast the overflow `chat:error` to the UI. The
  `source` is the call site (e.g.
  `"Nest.Agents.Agent.ChatPipeline.handle_preflight/2"` or
  `inspect(Nest.Agents.Agent.Compaction.Trigger)`) for log
  correlation. The `system_prompt` is the rendered string
  from `compose_vocation_config/5`; `reason` selects the
  message shape (see `message/4`).

  Does NOT change the agent's status — callers set the
  status they want (e.g. `chat_pipeline` sets
  `:context_overflow`; `trigger` leaves the status
  unchanged). The two paths have different status
  semantics and this module is the shared part, not the
  status policy.
  """
  @spec broadcast(Nest.Agents.Agent.t(), String.t(), verb(), String.t() | nil, reason()) :: :ok
  def broadcast(
        state,
        source,
        verb \\ "compact",
        system_prompt \\ nil,
        reason \\ :reserve_exhausted
      ) do
    Broadcasts.error(
      state.space_id,
      state.name,
      nil,
      message(state.llm_metrics.context_limit, system_prompt, verb, reason),
      source
    )
  end
end
