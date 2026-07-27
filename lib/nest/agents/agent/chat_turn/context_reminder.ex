defmodule Nest.Agents.Agent.ChatTurn.ContextReminder do
  @moduledoc """
  Mid-iteration context-usage reminders for the LLM.

  Whenever the chat task is about to make an LLM call, the
  ChatTurn's `iterate/1` checks the current context usage
  against a list of thresholds (25%, 50%, 75%). When a new
  threshold is crossed, the notice is deferred and attaches to
  the next tool response as a `Part.Text`, or is injected as a
  `[notice_user, ack_assistant]` pair when there are no pending
  tool results.

  Both sides of the pair carry information — the assistant ack
  primes the model's awareness for the next real response.

  Firing rules:
    * Each threshold fires at most once between compactions.
      The "already announced" set lives on
      `Nest.Agents.Agent.ChatState.crossed_thresholds` (per
      conversation, not per ChatTurn).
    * Only the highest currently-crossed threshold is announced.
    * When compaction succeeds, the set is cleared.
    * If `context_limit` is unknown (nil), no warning is injected.

  Notice specs (the generic mechanism for Case 2 injection):

  `spec/3` returns a `%{kind, attention, notice}` map when a
  new threshold crosses, or `nil` otherwise. The attention text
  is the short string the LLM sees as a synthetic assistant
  message just before the notice; the notice text is the full
  format with token numbers. See `ResponseHandler.collect_case2_specs/2`
  for how specs are collected and injected.
  """

  alias Nest.LLM.ClientConfig
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Reserve

  @thresholds [
    {0.25, :p25},
    {0.50, :p50},
    {0.75, :p75}
  ]

  @ack_texts %{
    p25: "Okay, that's plenty of space.",
    p50: "Okay, I should consider conserving tokens.",
    p75: "Okay, no more expensive tool calls and I should consider explicitly compacting."
  }

  @notice_texts %{
    p25: "Context at 25%.",
    p50: "Context at 50%.",
    p75: "Context at 75%. Consider compacting via the context tool."
  }

  @type spec :: %{kind: atom(), attention: String.t(), notice: String.t()}

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
  Notice text for a threshold atom. Returns a short
  sentence the callers can attach to a tool response or
  use as the user side of a synthetic pair.
  """
  @spec notice_text(atom()) :: String.t()
  def notice_text(atom) do
    Map.fetch!(@notice_texts, atom)
  end

  @doc """
  Assistant ack text that pairs with a given notice.
  Primes the model's awareness for the next response.
  """
  @spec ack_text_for(atom()) :: String.t()
  def ack_text_for(atom) do
    Map.fetch!(@ack_texts, atom)
  end

  @doc """
  Build a complete notice spec for a context-usage threshold
  crossing. Returns the spec map (attention + notice) when a
  new threshold crosses, or `nil` otherwise. The attention
  text "Context?" signals to the LLM that the next user
  message is a context-usage reminder, distinguishing it
  from other notice types (e.g. tool-call budget).
  """
  @spec spec(non_neg_integer(), pos_integer(), MapSet.t(atom())) :: spec() | nil
  def spec(used, limit, crossed) do
    case highest_unannounced(used, limit, crossed) do
      nil ->
        nil

      atom ->
        %{
          kind: :context,
          attention: "Context?",
          notice: format(atom, used, limit)
        }
    end
  end

  @doc """
  Build a `{:user, _}` message from the given notice text.
  """
  @spec build_user_notice(String.t(), ClientConfig.t() | nil) :: {:user, User.t()}
  def build_user_notice(text, _client_config) do
    {:user,
     %User{
       parts: [%Part.Text{text: text}],
       timestamp: DateTime.utc_now(),
       api_logs: []
     }}
  end

  @doc """
  Build the reminder message for the given threshold atom.
  Kept for test compatibility and callers that need the
  legacy `{:system, _}` format. Prefer `notice_text/1`
  for new call sites.
  """
  @spec build_message(atom(), non_neg_integer(), pos_integer(), ClientConfig.t() | nil) ::
          {:system, Nest.Messages.System.t()} | {:user, User.t()}
  def build_message(atom, used, limit, client_config) do
    build_user_notice(format(atom, used, limit), client_config)
  end

  @spec build_message(atom(), non_neg_integer(), pos_integer()) ::
          {:system, Nest.Messages.System.t()} | {:user, User.t()}
  def build_message(atom, used, limit),
    do: build_message(atom, used, limit, %ClientConfig{})

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
  """
  @spec estimate_messages([term()]) :: non_neg_integer()
  def estimate_messages(messages) do
    ConversationSize.size(messages)
  end
end
