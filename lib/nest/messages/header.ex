defmodule Nest.Messages.Header do
  @moduledoc """
  The `[From … | mode: …]` header on every user-role row.

  A row's header states **who is speaking** and **the mode the recipient's turn
  will run in**. That is the whole point: a peer's words, a runtime notice and a
  human's prompt used to be told apart by three different mechanisms, and the
  model had to infer who was speaking from them.

      [From user | mode: act]
      [From user @nat | mode: act]
      [From user @nat, agents-send reply required | mode: act]
      [From agent crazy-dolphin | mode: plan]
      [From agent crazy-dolphin, agents-send reply required | mode: plan]
      [From nest runtime | mode: act]
      [From nest runtime | mode: compact]

  * The human arm is `user`, and it **names the human** whenever the producer
    has the name: `human?` is the fact, `from` is the name, and the row states
    it as the address a reply goes to — `[From user @nat …]`, the same string
    whether the producer passed `"nat"` or `"@nat"`. A row that says just
    `user` is a human whose name the producer did not have.
  * The sigil is how you *address* somebody in a tool argument
    (`Nest.Address`); it is not how a row that already knows its speaker is a
    human gets labelled. So the address clause below is for a sender written as
    one, which is a different fact from `human?` being true.
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
  (`assets/js/utils/stripHeader.js`), so the operator reads the body, never the
  wire line — but **not** at the cost of its facts: the sender and the reply
  marker have their own affordances (`assets/js/utils/header.js` — the row label,
  and a caption per body when a row holds several), and the mode is the row's
  badge. A header line is dropped only after that same parse has read it, and
  only when its mode clause agrees with the row's own, so a disagreement stays
  visible. The clipboard keeps the line verbatim: plain text has no badge, so
  there the sender is content.
  """

  @type sender :: :user | :runtime | {:user, String.t()} | {:agent, String.t() | nil}

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

  The facts answer it in this order, and the order is the rule:

    * **the inbox kind `:runtime`** — the runtime speaking, whatever name it
      carries: a notice about an agent must never be framed as that agent's
      words, nor as a human's. It is checked first so that nothing else can
      override it.
    * **`human?`** — the producer saying that what it is passing is a human's
      words. The row is `user`, and it names them from `from` (folded the way a
      username is stored, `Nest.Name`), because a row has to state *who* is
      speaking and a human's name is the address a reply is sent to. A producer
      with no name gets the bare `user`.
    * **otherwise the name it carries** — an *address* (`Nest.Address`) is a
      human's, which is how a note to a human is delivered and what a reply is
      sent to; a bare name is an agent's and is not folded, because it is an
      identifier rather than a written address, so `"Nat"` reads as that agent.
      A spawn kickoff lands here: a `kind: :user` entry that nobody typed, from
      the spawning agent.

  The sigil is how you *address* somebody in a tool argument; it is not how a
  row that already knows its speaker is a human gets labelled. Both roads end at
  the same string — `human?: true` with `"nat"` and a note from `"@nat"` both
  read `[From user @nat …]` — which is what stops a queued human message and an
  idle one, or a chat and a note, from having two spellings.

  A missing or blank name says `agent`, except on a human's row, which says
  `user`: the row must not read as the other class, and printing `nil` would be
  worse than leaving the name out.
  """
  @spec sender(String.t() | nil, boolean(), atom() | nil) :: sender()
  def sender(from, human?, kind \\ nil)

  def sender(_from, _human?, :runtime), do: :runtime
  def sender(from, true, _kind), do: named_user(from)

  def sender(from, _human?, _kind) when is_binary(from) do
    case Nest.Address.parse(from) do
      {:user, username} -> {:user, username}
      {:agent, _name} -> {:agent, from}
    end
  end

  def sender(from, _human?, _kind), do: {:agent, from}

  # A human's row names them, from the name the producer has — folded the way a
  # username is stored (`Nest.Name`), so the row and the address an agent would
  # write for that person are one string. No name is `:user`: the row must not
  # read as an agent's, and the name is genuinely unknown.
  defp named_user(from) when is_binary(from) do
    case Nest.Name.sanitize(from) do
      "" -> :user
      username -> {:user, username}
    end
  end

  defp named_user(_from), do: :user

  defp who(:user), do: "user"
  defp who(:runtime), do: "nest runtime"
  defp who({:user, username}) when is_binary(username) and username != "", do: "user @#{username}"
  defp who({:user, _username}), do: "user"
  defp who({:agent, name}) when is_binary(name) and name != "", do: "agent #{name}"
  defp who({:agent, _name}), do: "agent"
end
