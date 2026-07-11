defmodule Nest.Messages.ThinkTags do
  @moduledoc """
  Strip `<think>...</think>` content from text. Used by the
  compactor's LLM call (see `Nest.Agents.Agent.Compaction`):
  the compactor sends the agent's prior conversation to the
  summarization LLM and wants to remove the prior turn's
  reasoning content so the compactor sees clean text (the
  reasoning already happened — repeating it inflates the
  summary without adding signal). The summary itself is
  stored intact; only the LLM call's input is stripped.

  ## Behavior

  `<think>...</think>` blocks are removed from the text. The
  markers themselves are stripped; the inner content goes to
  `:none`. Surrounding text is preserved.

    * No markers → returns the input unchanged.
    * One block → returns the text with the block removed.
    * Multiple blocks → returns the text with each block removed.
    * Nested `<think>` inside a think block → the inner
      `<think>` is treated as text inside the think block
      (no recursion), but its matching `</think>` is
      consumed to keep the outer block from closing early.
      The outer block closes only at depth 0.
    * Empty think block (`<think></think>`) → removed (zero
      contribution).
    * Orphan `</think>` (no matching `<think>`) → the orphan
      and everything from the orphan to the end of the string
      is removed. Stray `</think>` text in a response is
      model reasoning, not user-visible content — it should
      not reach the compactor LLM.
    * Orphan `<think>` (no matching `</think>`) → everything
      from the orphan to the end of the string is removed
      (an incomplete think block — also reasoning content).

  ## Relationship to JS

  Mirrors `assets/js/utils/thinkTags.js`'s `splitThinkTags`:
  the JS side splits so the UI can render the thinking as a
  collapsed block; the Elixir side strips so the LLM sees
  clean text. Same algorithm, opposite direction.
  """

  @opening_tag "<think>"
  @closing_tag "</think>"
  @opening_tag_len byte_size(@opening_tag)
  @closing_tag_len byte_size(@closing_tag)

  @doc """
  Strip `<think>...</think>` blocks from `text`. See the
  module doc for the full behavior.
  """
  @spec strip(String.t()) :: String.t()
  def strip(text) when is_binary(text) do
    strip(text, 0, [])
  end

  def strip(_), do: ""

  # `depth` is the number of `<think>` openers minus `</think>`
  # closers we've seen. depth == 0 means we're in text mode;
  # depth > 0 means we're inside one or more think blocks.
  # `acc` is the reverse-order IO list of completed text runs.
  defp strip("", _depth, acc), do: finalize(acc)

  defp strip(text, 0, acc) do
    case next_in_text_mode(text) do
      :none ->
        finalize(acc) <> text

      {:open, idx} ->
        before_marker = binary_part(text, 0, idx)
        new_acc = push_if_nonempty(acc, before_marker)
        tail = tail_after(text, idx, @opening_tag_len)
        strip(tail, 1, new_acc)

      {:orphan_close, idx} ->
        before_marker = binary_part(text, 0, idx)
        new_acc = push_if_nonempty(acc, before_marker)
        finalize(new_acc)
    end
  end

  defp strip(text, depth, acc) when depth > 0 do
    case next_in_thinking_mode(text) do
      :none ->
        # No more markers — discard the rest (it's all reasoning).
        finalize(acc)

      {:close, idx} ->
        tail = tail_after(text, idx, @closing_tag_len)
        strip(tail, depth - 1, acc)

      {:open, idx} ->
        tail = tail_after(text, idx, @opening_tag_len)
        strip(tail, depth + 1, acc)
    end
  end

  # Find the next marker in text mode (depth = 0). Returns
  # `:none` if no markers; otherwise `{:open, idx}` for a
  # `<think>` opener or `{:orphan_close, idx}` for an orphan
  # `</think>` (treated as the start of a thinking segment).
  defp next_in_text_mode(text) do
    open_idx = match_index(text, @opening_tag)
    close_idx = match_index(text, @closing_tag)

    case {open_idx, close_idx} do
      {nil, nil} -> :none
      {oi, nil} -> {:open, oi}
      {nil, ci} -> {:orphan_close, ci}
      {oi, ci} when oi <= ci -> {:open, oi}
      {_oi, ci} -> {:orphan_close, ci}
    end
  end

  # Find the next marker in thinking mode (depth > 0). Returns
  # `:none` if no markers; otherwise the first marker by
  # index. `<think>` opens a nested level (depth+1), `</think>`
  # closes the current level (depth-1). Whichever comes first
  # wins — depth tracking ensures the matching `</think>` is
  # consumed before a stray `</think>` later in the text can
  # close the outer block.
  defp next_in_thinking_mode(text) do
    open_idx = match_index(text, @opening_tag)
    close_idx = match_index(text, @closing_tag)

    case {open_idx, close_idx} do
      {nil, nil} -> :none
      {oi, nil} -> {:open, oi}
      {nil, ci} -> {:close, ci}
      {oi, ci} when oi <= ci -> {:open, oi}
      {_oi, ci} -> {:close, ci}
    end
  end

  defp finalize(acc), do: acc |> :lists.reverse() |> IO.iodata_to_binary()

  defp push_if_nonempty(acc, ""), do: acc
  defp push_if_nonempty(acc, str), do: [str | acc]

  defp tail_after(text, idx, marker_len) do
    tail_start = idx + marker_len
    size = byte_size(text)
    binary_part(text, tail_start, size - tail_start)
  end

  defp match_index(text, marker) do
    case :binary.match(text, marker) do
      {idx, _} -> idx
      :nomatch -> nil
    end
  end

  @doc """
  Walk a message's `parts` list, rewriting each `Part.Text`
  to strip `<think>...</think>` content from its `text`
  field. All other part kinds pass through unchanged. Returns
  the rewritten parts list (same length as input).
  """
  @spec strip_from_parts([Nest.Messages.Part.t()]) :: [Nest.Messages.Part.t()]
  def strip_from_parts(parts) when is_list(parts) do
    Enum.map(parts, fn
      %Nest.Messages.Part.Text{text: text} = part ->
        %{part | text: strip(text)}

      part ->
        part
    end)
  end

  def strip_from_parts(_), do: []
end
