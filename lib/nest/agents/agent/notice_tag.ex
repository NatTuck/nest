defmodule Nest.Agents.Agent.NoticeTag do
  @moduledoc """
  The `[nest notice]` wire-level marker on a synthetic runtime notice.

  A notice is the runtime speaking for itself: a context-usage or budget
  reminder, a backgrounded batch's outcome, a stop cancellation, a lost
  promise. `AGENTS.md` says system notices carry a `[Nest notice]` prefix, and
  this module is that marker's one home — exactly as the `[mode: <name>]`
  prefix has one writer (`Turn.Dispatch.build_user_message/3`) rather than a
  copy in every builder.

  The marker is a **wire-level** one: it is at the head of the notice text in
  the message the model reads and in the persisted row, and the client strips
  it on render (`assets/js/utils/stripNoticePrefix.js`, its own copy of the
  string, reached from the same places that strip `[mode: <name>]`), so the
  operator never sees it.

  Only the notice itself is tagged. The synthetic attention line (`Context?`,
  `Tool limit?`) and the acknowledgement that closes the pair are untagged —
  they are the runtime framing the notice, not the notice — and no other
  message is tagged at all.

  `tag/1` puts the marker on its own line at the head of `text`. Every builder
  that emits a notice calls it, so the marker is always at the head of a row's
  text and never mid-text; that is what keeps the client's strip a simple
  leading-prefix removal.
  """

  @tag "[nest notice]"

  @doc """
  `text` with the notice marker at the head of its own line.
  """
  @spec tag(String.t()) :: String.t()
  def tag(text) when is_binary(text), do: @tag <> "\n" <> text
end
