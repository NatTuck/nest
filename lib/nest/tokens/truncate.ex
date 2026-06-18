defmodule Nest.Tokens.Truncate do
  @moduledoc """
  Head-truncation for tool results that exceed the context budget.

  When a tool returns a result that would blow the context window,
  the BudgetPlanner passes the result here to chop it down. We
  keep the head of the string (most useful signal for code, logs,
  and structured output) and append a note explaining the cut.

  The chunk size is computed in **tokens** (via `Nest.Tokens.Estimator`)
  and then converted to a byte cap for the actual binary slice. We
  use a 4-bytes-per-token worst case so the byte slice never
  exceeds the requested token budget, even on UTF-8-heavy content.
  """

  alias Nest.Tokens.Estimator

  @bytes_per_token 4

  @doc """
  Truncates `content` so it fits in `max_tokens`. Returns just the
  truncated content without any note.
  """
  @spec head(String.t(), pos_integer()) :: String.t()
  def head(content, max_tokens) when is_binary(content) and is_integer(max_tokens) do
    byte_cap = max(0, max_tokens) * @bytes_per_token

    if byte_size(content) <= byte_cap do
      content
    else
      binary_part(content, 0, byte_cap)
    end
  end

  def head(_, _), do: ""

  @doc """
  Returns a one-line note explaining the truncation.
  """
  @spec note(String.t(), pos_integer()) :: String.t()
  def note(original, kept_tokens) when is_binary(original) and is_integer(kept_tokens) do
    original_tokens = Estimator.raw_count(original)
    "\n\n[truncated: original ~#{original_tokens} tokens, kept first ~#{kept_tokens} tokens]"
  end

  def note(_, _), do: "\n\n[truncated]"

  @doc """
  Truncates and appends the note in one call. Returns
  `{truncated_content, note}` so the caller can budget each piece
  separately.

  The note consumes `note_tokens` (default 40) of the budget. The
  kept content is sized to `max_tokens - note_tokens`.
  """
  @spec head_with_note(String.t(), pos_integer(), pos_integer()) ::
          {String.t(), String.t()}
  def head_with_note(content, max_tokens, note_tokens \\ 40)
      when is_binary(content) and is_integer(max_tokens) do
    kept_budget = max(0, max_tokens - note_tokens)
    kept = head(content, kept_budget)
    note = note(content, Estimator.raw_count(kept))
    {kept, note}
  end
end
