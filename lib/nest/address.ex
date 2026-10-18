defmodule Nest.Address do
  @moduledoc """
  An address: **`@<username>` for a human, `<name>` for an agent**.

  The sigil is required for a human and is the *only* thing that tells the two
  apart: a human `nat` and an agent `nat` may both exist in a space
  (`notes/space-chat.md` § "The address"), and nothing in a name distinguishes
  them. That is why `Nest.Notes.UserNote` carries `to_kind`/`from_kind` beside
  the names, and why the send tools' "not found" error says which of the two it
  looked for and what the other would have looked like.

  ## Why the sigil makes the name foldable

  `@Nat` is the human `nat`: the sigil says the text is an *address*, written to
  be read back, so it is folded through `Nest.Name.sanitize/1` — the same rule
  `Nest.Accounts.User` stores usernames by, which is what makes the two
  spellings one address rather than a lookup the caller has to get right.

  A **bare** name is not folded, because it is not an address: it is an agent's
  identifier, and picking the row a near-miss spelling might have meant is worse
  than failing. `"Nat"` therefore names no agent, and the error names the human
  `@nat` it could have meant — which is the one thing a model that dropped the
  sigil needs to be told.

  ## What is here and what is not

  `parse/1`, `format/1` and `user?/1` are pure: no database, no registry. Whether
  an address names anybody, and the wording of a refusal, are the callers'
  (`Nest.Notes` for a human, `Nest.Agents.Supervisor` for an agent,
  `Nest.Agents.target_error/2` for the sentence).
  """

  @typedoc "A parsed address: a human's username, or an agent's name."
  @type t :: {:user, String.t()} | {:agent, String.t() | nil}

  @doc """
  Parse `target` into an address.

  `"@nat"` is the human `nat`; `"crazy-dolphin"` is that agent. The username is
  folded (`"@Nat"` and `"@nat"` are one human); the agent name is taken as
  written. `nil` and any non-binary are an *unnamed* agent, which is what an
  entry with no sender is — it must not read as a human's.
  """
  @spec parse(term()) :: t()
  def parse("@" <> username), do: {:user, Nest.Name.sanitize(username)}
  def parse(name), do: {:agent, name}

  @doc """
  The written form of an address: `@nat` for a human, the bare name for an
  agent.

  An unnamed agent formats to `nil`, which is the value the inbox stores for a
  sender it does not have — `nil` rather than `""`, so the two cannot be
  confused for a name nothing can carry.
  """
  @spec format(t()) :: String.t() | nil
  def format({:user, username}), do: "@" <> username
  def format({:agent, nil}), do: nil
  def format({:agent, name}), do: name

  @doc """
  Whether `target` is a human address — `@` followed by anything.

  A *classification*, not a resolution: `"@nobody"` is a human address that
  names nobody, and it is still an address (which is what the refusal needs to
  say).
  """
  @spec user?(term()) :: boolean()
  def user?(target), do: match?({:user, _}, parse(target))
end
