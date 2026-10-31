defmodule Nest.Messages.ThinkTags do
  @moduledoc """
  Strip a **leading** `<think>...</think>` block from text.

  Used on the model's own output: `Nest.Agents.Agent.Turn.Executor`'s
  `commit_compaction/2` strips the summary before it is stored, and
  `Nest.Tokens.Compactor.validate_summary/1` asks whether what is left is empty
  (the "the model emitted only reasoning" check).

  ## The rule

  A marker is wire framing only when the fact it carries has a home elsewhere.
  The only home this build writes is the leading block: the server emits at most
  one `Part.Thinking`, first
  (`Nest.Agents.Agent.Turn.Messages.build_assistant_parts/1`, with the comment
  that Anthropic requires the thinking block to lead). So only a **leading,
  matched** pair is stripped:

    * the text starts with `<think>` and a `</think>` follows → everything
      through the **first** `</think>` is removed;
    * anything else → the text is returned unchanged.

  That second clause is the point. This module used to treat an orphan
  `</think>` as the start of a reasoning run and delete everything to the end of
  the string, and an unclosed `<think>` the same way — so a model that merely
  *discussed* the tag lost the rest of its output. A `<think>` in the middle of
  prose, an unclosed `<think>`, and a stray `</think>` are all text.

  Nesting is not supported: the block ends at the first `</think>`, which is the
  honest reading of a marker nothing writes any more.

  ## Relationship to JS

  `assets/js/utils/thinkTags.js`'s `leadingThinkBlock/1` is the same rule, and
  `assets/js/utils/messageParts.js`'s `splitReasoning/1` is where the display
  side decides that this block is the reasoning channel (for an assistant row
  with no `Part.Thinking`, and never for any other role). The JS side splits so
  the UI can render the thinking as a collapsed block; the Elixir side strips so
  the stored summary and the emptiness check see clean text. Same rule, opposite
  direction.
  """

  @opening_tag "<think>"
  @closing_tag "</think>"

  @doc """
  Remove the leading `<think>...</think>` block from `text`, or return `text`
  unchanged when it does not start with one. See the module doc.
  """
  @spec strip(String.t()) :: String.t()
  def strip(text) when is_binary(text) do
    with true <- String.starts_with?(text, @opening_tag),
         [_, rest] <- String.split(text, @closing_tag, parts: 2) do
      rest
    else
      _ -> text
    end
  end

  def strip(_), do: ""
end
