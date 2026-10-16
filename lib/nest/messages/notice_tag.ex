defmodule Nest.Messages.NoticeTag do
  @moduledoc """
  The `[nest notice]` wire-level marker on a synthetic runtime notice.

  A notice is the runtime speaking for itself: a context-usage or budget
  reminder, a backgrounded batch's outcome, a stop cancellation, a lost
  promise, a reply obligation, a re-prompt nudge, a workspace change. The
  marker is a **property of a message's text** on the wire — exactly like the
  `[mode: <name>]` prefix — so it lives here in the message layer, which is
  also the only layer every writer can reach: the builders that put a notice in
  the transcript live both in `Nest.Agents.Agent` (`NoticePairInjector`,
  `Inbox.Render`, `Machine.Response`, `Machine.Compaction`,
  `WorkspaceHandler`) and in `Nest.Messages` (`MessageList.continuation_prompt/0`,
  the wire-repair row the runtime writes to the model).

  `AGENTS.md` says system notices carry a `[Nest notice]` prefix, and this
  module is that marker's one home, rather than a copy in every builder.

  The marker is a **wire-level** one: it is at the head of the notice text in
  the message the model reads and in the persisted row, and the client strips
  it on render (`assets/js/utils/stripNoticePrefix.js`, its own copy of the
  string, reached from the same places that strip `[mode: <name>]`), so the
  operator never sees it.

  Only the notice itself is tagged. The synthetic attention line (`Context?`,
  `Tool limit?`) and the acknowledgement that closes a pair are untagged —
  they are the runtime framing the notice, not the notice — and no other
  message is tagged at all.

  `tag/1` puts the marker on its own line at the head of `text`. Every builder
  that emits a notice calls it, so the marker is always at the head of a
  *body*; a delivered batch joins bodies with a blank line, which is why the
  client's strip removes a marker at the head of the content or of any body
  rather than only the very first line.
  """

  @tag "[nest notice]"

  @doc """
  `text` with the notice marker at the head of its own line.
  """
  @spec tag(String.t()) :: String.t()
  def tag(text) when is_binary(text), do: @tag <> "\n" <> text
end
