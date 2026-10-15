defmodule Nest.Agents.Agent.Turn.ContextReminder do
  @moduledoc """
  Mid-iteration context-usage reminders for the LLM.

  Thresholds (25%, 50%, 75%) measure against the *working* budget
  (`context_limit - Reserve.compaction_reserve/1`), not the raw
  window. Each threshold fires at most once between compactions; the
  "already announced" set lives on `state.live.crossed_thresholds`.
  """

  alias Nest.LLM.ClientConfig
  alias Nest.Messages.NoticeTag
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Tokens.ConversationSize
  alias Nest.Tokens.Reserve

  @thresholds [
    {0.25, :p25},
    {0.50, :p50},
    {0.75, :p75}
  ]

  # The decided notice wording. The 25% notice is a bare statement: models do
  # not start worrying about context until the 50% notice, so only 50% and 75%
  # tell the model to keep working rather than stop. The 75% notice has two
  # variants: one for an agent that owns the `context-compact` tool (it may
  # compact itself) and one for an agent whose vocation lacks it (it must not be
  # told to use a tool it does not have).
  @notice_texts %{
    p25: "Context at 25%.",
    p50:
      "Context at 50%. Do not stop due to context concerns, continue working through compaction."
  }

  @p75_notice_compact "Context at 75%. Do not stop due to context concerns, " <>
                        "either explicitly compact yourself with the context-compact tool " <>
                        "or continue working through compaction."

  @p75_notice_plain "Context at 75%. Do not stop due to context concerns, " <>
                      "continue working through compaction."

  # Every context threshold acknowledges the same way. The ack is not where the
  # model is steered — the notice is — so it is one sentence for all three
  # thresholds and both 75% variants.
  @ack_text "Okay, context noted."

  @type spec :: %{
          required(:kind) => atom(),
          required(:attention) => String.t(),
          required(:notice) => String.t(),
          optional(:threshold) => atom(),
          optional(:ack) => String.t()
        }

  @doc """
  Returns the highest threshold atom that is currently
  crossed but not yet in `crossed`, or `nil`.
  """
  @spec highest_unannounced(non_neg_integer(), pos_integer(), MapSet.t(atom())) ::
          atom() | nil
  def highest_unannounced(_used, limit, _crossed) when limit <= 0, do: nil

  def highest_unannounced(used, limit, crossed) do
    reserve = Reserve.compaction_reserve(limit)
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
  Notice text for a threshold atom.
  """
  @spec notice_text(atom(), boolean()) :: String.t()
  def notice_text(atom, compact? \\ true)

  def notice_text(:p75, true), do: @p75_notice_compact
  def notice_text(:p75, false), do: @p75_notice_plain
  def notice_text(atom, _compact?), do: Map.fetch!(@notice_texts, atom)

  @doc """
  The assistant ack text that pairs with a context notice.

  Every context threshold acknowledges identically — the ack is not where the
  model is steered, the notice is — so there is one ack, not one per threshold
  and no `compact?` variant.
  """
  @spec ack_text() :: String.t()
  def ack_text, do: @ack_text

  @doc """
  Whether the agent owns the `context-compact` tool.
  """
  @spec compact_available?([Nest.LLM.Tool.t()] | nil) :: boolean()
  def compact_available?(tools), do: Enum.any?(tools || [], &(&1.name == "context-compact"))

  @doc """
  Build a complete notice spec for a context-usage threshold crossing.
  """
  @spec spec(non_neg_integer(), pos_integer(), MapSet.t(atom()), boolean()) :: spec() | nil
  def spec(used, limit, crossed, compact? \\ true) do
    case highest_unannounced(used, limit, crossed) do
      nil ->
        nil

      atom ->
        %{
          kind: :context,
          attention: "Context?",
          notice: notice_text(atom, compact?),
          threshold: atom
        }
    end
  end

  @doc """
  Metadata stamp for a notice spec, or `nil`.
  """
  @spec context_metadata(spec()) :: %{String.t() => String.t()} | nil
  def context_metadata(%{kind: :context, threshold: atom}) when is_atom(atom) do
    %{"context_threshold" => Atom.to_string(atom)}
  end

  def context_metadata(_spec), do: nil

  @threshold_atoms [:p25, :p50, :p75]

  @doc """
  The set of context-usage thresholds already announced in the
  given active message list.
  """
  @spec announced_thresholds([term()]) :: MapSet.t(atom())
  def announced_thresholds(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(&message_threshold/1)
    |> MapSet.new()
  end

  defp message_threshold({_role, %{metadata: %{} = metadata}}) do
    case metadata["context_threshold"] || metadata[:context_threshold] do
      value when is_binary(value) -> List.wrap(find_threshold(value))
      _ -> []
    end
  end

  defp message_threshold(_message), do: []

  defp find_threshold(value), do: Enum.find(@threshold_atoms, &(Atom.to_string(&1) == value))

  @doc """
  Build a `{:user, _}` message from the given notice text.
  """
  @spec build_user_notice(String.t(), ClientConfig.t() | nil, map() | nil) :: {:user, User.t()}
  def build_user_notice(text, _client_config, metadata \\ nil) do
    {:user,
     %User{
       parts: [%Part.Text{text: text}],
       timestamp: DateTime.utc_now(),
       metadata: metadata,
       api_logs: []
     }}
  end

  @doc """
  Build the context-notice row for the given threshold atom.

  The row is exactly the one the live paths announce: the decided text
  (`notice_text/2`) on the `{:user, _}` row `build_user_notice/3` builds,
  carrying the `[nest notice]` marker (`NoticeTag.tag/1`). `compact?` picks the
  75% variant, as it does for the text itself.

  It takes no counts because the decided wording carries none — the used and
  effective token counts were the *legacy* verbose form's (`format/4`), and a
  parameter that no longer reaches the row would read as if it still did.
  """
  @spec build_message(atom(), boolean()) :: {:user, User.t()}
  def build_message(atom, compact? \\ true) do
    build_user_notice(NoticeTag.tag(notice_text(atom, compact?)), nil)
  end

  @doc false
  @spec format(atom(), non_neg_integer(), pos_integer(), boolean()) :: String.t()
  def format(atom, used, limit, compact? \\ true)

  def format(:p25, used, limit, _compact?), do: percentage_text(25, used, limit)

  def format(:p50, used, limit, _compact?), do: percentage_text(50, used, limit)

  def format(:p75, used, limit, compact?) do
    base = percentage_text(75, used, limit)

    if compact? do
      base <> " Consider compacting via the `context-compact` tool to free up room."
    else
      base
    end
  end

  defp percentage_text(pct, used, limit) do
    reserve = Reserve.compaction_reserve(limit)
    effective = max(1, limit - reserve)
    "Context usage is now at #{pct}% (~#{used} of ~#{effective} token budget)."
  end

  @doc """
  Estimate the token count for the given messages list.
  """
  @spec estimate_messages([term()]) :: non_neg_integer()
  def estimate_messages(messages) do
    ConversationSize.size(messages)
  end
end
