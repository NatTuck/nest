defmodule Nest.Agents.Agent.ChatTurn.ContextReminder do
  @moduledoc """
  Mid-iteration context-usage reminders for the LLM.

  Whenever the chat task is about to make an LLM call, the
  ChatTurn's `iterate/1` checks the current context usage
  against a list of thresholds (25%, 50%, 75%). When a new
  threshold is crossed, a `{:system, _}` message is appended
  to the conversation so the LLM can plan ahead (e.g. switch
  to `head`/`tail` reads, call the `context` tool to
  compact, or stop adding new tool results).

  Firing rules:
    * Each threshold fires at most once between compactions.
      The "already announced" set lives on
      `Nest.Agents.Agent.ChatState.crossed_thresholds` (per
      conversation, not per ChatTurn — the ChatTurn is one
      per user message and would reset the set every turn).
    * Only the highest currently-crossed threshold is announced
      (so a fresh turn starting at 60% fires 50%, not 25+50).
    * When compaction succeeds, the set is cleared in
      `Compaction.ResultHandler.handle_success/3` so the
      thresholds re-fire if usage rises again after the
      history was summarized.
    * If `context_limit` is unknown (nil), no warning is
      injected.

  Threshold text is fixed at the threshold value (25/50/75%);
  the dynamic numbers (`{used}`, `{limit}`) are the live
  estimate and configured/probed limit. The percentages use
  the threshold label, not the live ratio — the live ratio
  might be 27% or 53% but the message says "25%" / "50%".
  Close enough for the LLM's planning purposes.

  Extracted from `Nest.Agents.Agent.ChatTurn` to keep that
  module under the 500-line Credo cap.
  """

  alias Nest.Agents.Agent.ChatTurn.LateMessage
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Reserve

  # Ordered list of thresholds. `highest_unannounced/3` takes
  # the last one whose `pct` is met, so the list MUST stay
  # ordered low-to-high. Add a `:p90` here when a 90% warning
  # becomes desirable.
  #
  # Thresholds are measured against the **working token budget**
  # (`context_limit - reserve`), not the raw context_limit.
  # The reserve is set aside so the compactor's own LLM call
  # has headroom — see `Nest.Tokens.Reserve` for the formula.
  # This means warnings fire earlier in absolute terms, which is
  # correct: the LLM should plan around the working budget.
  @thresholds [
    {0.25, :p25},
    {0.50, :p50},
    {0.75, :p75}
  ]

  @doc """
  Returns the highest threshold atom that is currently
  crossed but not yet in `crossed`, or `nil` if no new
  threshold should be announced.
  """
  @spec highest_unannounced(non_neg_integer(), pos_integer(), MapSet.t(atom())) ::
          atom() | nil
  def highest_unannounced(_used, limit, _crossed) when limit <= 0, do: nil

  def highest_unannounced(used, limit, crossed) do
    reserve = Reserve.response_budget(limit)
    effective = max(1, limit - reserve)
    ratio = used / effective

    @thresholds
    |> Enum.filter(fn {pct, _atom} -> ratio >= pct end)
    |> List.last()
    |> case do
      nil -> nil
      {_pct, atom} -> if MapSet.member?(crossed, atom), do: nil, else: atom
    end
  end

  @doc """
  Build the reminder message for the given threshold atom with
  the live usage numbers interpolated, routed through the
  provider's `rewrite_late_system_messages` config.

  Returns `{:system, %System{…}}` by default; returns
  `{:user, %User{parts: [%Part.Text{text: "[System notice:
  …]"}]}}` when the provider flag is on. See
  `Nest.Agents.Agent.ChatTurn.LateMessage.build/2` for the
  flag's purpose.

  The arity-3 form is kept for tests and any callers without a
  fully-built `ClientConfig` — it delegates with an off-config.
  """
  @spec build_message(atom(), non_neg_integer(), pos_integer(), ClientConfig.t() | nil) ::
          {:system, System.t()} | {:user, User.t()}
  def build_message(atom, used, limit, client_config) do
    LateMessage.build(client_config, format(atom, used, limit))
  end

  @spec build_message(atom(), non_neg_integer(), pos_integer()) ::
          {:system, System.t()} | {:user, User.t()}
  def build_message(atom, used, limit),
    do: build_message(atom, used, limit, %ClientConfig{rewrite_late_system_messages: false})

  # Public for testability. Internal callers go through
  # `build_message/3`; tests assert the threshold-specific
  # text directly.
  @doc false
  @spec format(atom(), non_neg_integer(), pos_integer()) :: String.t()
  def format(:p25, used, limit) do
    reserve = Reserve.response_budget(limit)
    effective = max(1, limit - reserve)
    "Context usage is now at 25% (~#{used} of ~#{effective} token budget)."
  end

  def format(:p50, used, limit) do
    reserve = Reserve.response_budget(limit)
    effective = max(1, limit - reserve)
    "Context usage is now at 50% (~#{used} of ~#{effective} token budget)."
  end

  def format(:p75, used, limit) do
    reserve = Reserve.response_budget(limit)
    effective = max(1, limit - reserve)

    "Context usage is now at 75% (~#{used} of ~#{effective} token budget). " <>
      "Consider compacting via the `context` tool " <>
      "(action: 'compact') to free up room."
  end

  @doc """
  Estimate the token count for the given messages list.
  Exposed so the ChatTurn can call it once per iterate and
  pass the result into `highest_unannounced/3` and
  `build_message/3` without re-computing.

  Thin wrapper over `Nest.Tokens.ConversationSize.size/1`
  — kept here so the chat-turn call site only depends on
  this module, not the size/estimator directly. Makes
  future refinements (e.g. provider-specific tokenizers) a
  one-file change. The name is preserved for backward
  compatibility with existing call sites.
  """
  @spec estimate_messages([term()]) :: non_neg_integer()
  def estimate_messages(messages) do
    ConversationSize.size(messages)
  end
end
