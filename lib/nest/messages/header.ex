defmodule Nest.Messages.Header do
  @moduledoc """
  The `[From … | mode: …]` header on every user-role row.

  A row's header states **who is speaking** and **the mode the recipient's turn
  will run in**. That is the whole point: a peer's words, a runtime notice and a
  human's prompt used to be told apart by three different mechanisms, and the
  model had to infer who was speaking from them.

      [From user | mode: act]
      [From user, agents-send reply required | mode: act]
      [From agent crazy-dolphin | mode: plan]
      [From agent crazy-dolphin, agents-send reply required | mode: plan]
      [From nest runtime | mode: act]
      [From nest runtime | mode: compact]

  * The human arm carries **no name yet**; `@nat` arrives with `Nest.Name`. The
    human arm is therefore exactly `user`, and that is deliberate.
  * `, agents-send reply required` maps to exactly one predicate: the note's
    kind is `:query` (`Nest.Agents.Agent.Inbox.t:kind/0`). Nothing else sets it,
    and the compaction request never does — the response it wants is the model's
    own turn, not an `agents-send`.
  * The mode is the **recipient's** mode at delivery, exactly as the retired
    `[mode: X]` prefix stated it. Nothing about the mode machinery changed.

  **A single-sender row states it once; a batch states each body's sender.** A
  drained batch is one user row holding several entries, so it has no outer
  header and each entry's body carries its own
  (`Nest.Agents.Agent.Inbox.Render`). A row built with no sender — a batch, and
  the legacy held-message fixture shape — gets no header at all.

  The header is a property of a row's **text**, which is why it lives in the
  message layer: the builders that put a user row in the transcript live both in
  `Nest.Agents.Agent` (`ChatPipeline`, `Inbox.Render`, `NoticePairInjector`,
  `Machine.Response`, `Machine.Compaction`, `WorkspaceHandler`) and in
  `Nest.Messages` (`MessageList.continuation_prompt/1`).

  The client removes the header at render time
  (`assets/js/utils/stripHeader.js`, which also still removes the markers this
  replaced from rows recorded before it), so the operator reads the body and the
  badge, never the framing.
  """

  @type sender :: :user | :runtime | {:agent, String.t() | nil}

  @doc """
  The header line for `sender` in `mode`, with the reply marker when
  `reply_required?`.
  """
  @spec line(sender(), String.t(), boolean()) :: String.t()
  def line(sender, mode, reply_required? \\ false)

  def line(sender, mode, true),
    do: "[From #{who(sender)}, agents-send reply required | mode: #{mode}]"

  def line(sender, mode, _reply_required?), do: "[From #{who(sender)} | mode: #{mode}]"

  @doc """
  `text` with `sender`'s header at the head of its own line.
  """
  @spec put(String.t(), sender(), String.t(), boolean()) :: String.t()
  def put(text, sender, mode, reply_required? \\ false),
    do: line(sender, mode, reply_required?) <> "\n" <> text

  @doc """
  Whether `text`'s header says the runtime wrote it.

  Matched on the sender alone, not on the whole `[From nest runtime | mode: …]`
  shape: a runtime row that ever carried `, agents-send reply required` would
  otherwise read as somebody else's. Nothing produces that shape today — the
  reply marker is set from `kind == :query`, and a query's sender is an agent —
  but that invariant lives in `Inbox.Render`, not here, and a reader that
  under-counts is worse than one that is merely less specific.
  """
  @spec runtime?(String.t()) :: boolean()
  def runtime?(text), do: String.starts_with?(text, "[From nest runtime")

  @doc """
  The body behind `text`'s header, or `nil` when it has none.

  The counterpart of `put/4` for a reader that compares **bodies**: the mode a
  row was written under is part of its header, not its body, so a comparison
  over bodies does not depend on it. `Machine.Response`'s retry bound needs
  exactly that — the bound counts what was appended, and a turn that changed the
  mode must not reset it.
  """
  @spec body(String.t()) :: String.t() | nil
  def body(text) do
    with true <- String.starts_with?(text, "[From "),
         [_header, body] <- String.split(text, "\n", parts: 2) do
      body
    else
      _ -> nil
    end
  end

  @doc """
  Who a row is from, from the three facts every producer already has.

  `human?` wins over `from`, and the inbox kind decides the runtime arm, so a
  drain entry and an idle chat turn state the same sender for the same facts:
  a human's own words are `user` whatever name the channel passes; a note the
  runtime produced is `nest runtime` whatever agent it is *about*; and anything
  else is the agent whose name it carries — including a spawn kickoff, which is
  a `kind: :user` entry that nobody typed.

  A missing or blank name still says `agent`: the row must not read as a
  human's, and putting `nil` in the prompt is worse than leaving the name out.
  """
  @spec sender(String.t() | nil, boolean(), atom() | nil) :: sender()
  def sender(from, human?, kind \\ nil)

  def sender(_from, true, _kind), do: :user
  def sender(_from, _human?, :runtime), do: :runtime
  def sender(from, _human?, _kind), do: {:agent, from}

  defp who(:user), do: "user"
  defp who(:runtime), do: "nest runtime"
  defp who({:agent, name}) when is_binary(name) and name != "", do: "agent #{name}"
  defp who({:agent, _name}), do: "agent"
end
