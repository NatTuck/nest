defmodule Nest.Name do
  @moduledoc """
  The one name rule: what an agent's name and a human's username both are.

  A name is **`[a-z0-9_-]+`**, at most 255 bytes — no spaces, no dots, no
  capitals. That is what makes `@<username>` tokenise as one token wherever an
  address is written (a tool argument, the composer's recipient field, a
  `[From …]` header), and it is the same rule for humans and agents: `@Nat` and
  `@nat` are one human and `Nat` and `nat` are one agent, because neither can
  exist.

  An agent's name is also its **scratch-directory segment**
  (`Nest.Agents.Agent.TmpSpace.agent_dir/3`), so the rule is a filesystem one as
  well: `..` would escape the scratch root and a 258-byte component raises
  `:enametoolong`. Both consumers — `Nest.Agents.PersistedAgent` at the DB
  boundary and `Nest.Accounts.User` on the way in — read the rule from here
  rather than spelling it again, so the two cannot diverge.

  `sanitize/1` is the *transform* that brings an arbitrary string up to the rule;
  `valid?/1` is the check. Nothing here touches the database, the filesystem or
  a name that already exists — `priv/repo/migrations/20261022000000_lowercase_names.exs`
  brings existing rows up to the rule, and it inlines this module's rules rather
  than calling them (a data migration keeps doing what it did when it ran).
  """

  @max_bytes 255

  # The rule. Lowercase only: the charset is the same for humans and agents, and
  # a capital in either would make two spellings of one address.
  @pattern ~r/\A[a-z0-9_-]+\z/

  # Runs of characters that are not allowed in a name, matched with the `u` flag
  # so a multi-byte character is one run rather than one per byte.
  #
  # The fold is idempotent, but it is **not** the identity on every valid name:
  # `String.trim("-")` removes leading and trailing dashes, and the pattern
  # allows those, so `"-nat"` folds to `"nat"` and `"nat-"` to `"nat"`. A dash
  # on the edge is the one thing `sanitize/1` changes that `valid?/1` would
  # already accept.
  @unsafe_run ~r/[^a-z0-9_-]+/u

  # Combining marks left by NFD decomposition, stripped so accented Latin
  # letters fold to their base letter instead of being dropped.
  @combining_marks ~r/[\x{0300}-\x{036F}]+/u

  @doc "The pattern a name matches: `#{@pattern.source}`."
  @spec pattern() :: Regex.t()
  def pattern, do: @pattern

  @doc "The longest name, in bytes: the filesystem's component limit (`NAME_MAX`)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Whether `name` is a name: `#{@pattern.source}` and at most #{@max_bytes} bytes.

  The byte bound is the filesystem's rather than the column's. The character
  class is ASCII-only, so bytes and characters coincide, which is why the two
  limits agree today.
  """
  @spec valid?(term()) :: boolean()
  def valid?(name) do
    is_binary(name) and byte_size(name) <= @max_bytes and Regex.match?(@pattern, name)
  end

  @doc """
  The readable form of `name`: NFD-fold, lowercase, every run of other
  characters to `-`, trim the dashes.

  Deterministic, and as recognizable as it can be: `"Café ☕"` becomes `"cafe"`,
  `"Jane Doe"` becomes `"jane-doe"`, `".."` becomes `""`. It never *lengthens* a
  name in **bytes** — every character it emits is ASCII (one byte) and the
  output is at most as many bytes as the input — so it cannot push a name past
  the byte cap on its own. (It is not true in *characters*: a grapheme can
  normalize into a longer sequence and survive as a `-`, so a 255-character
  input can fold to more than 255 characters — but never to more than 255
  bytes.)

  **`""` means nothing survived.** An all-CJK name has no ASCII fold, and a name
  of nothing but punctuation is all separator. This function does not invent a
  substitute: `valid?/1` refuses `""`, so a caller that must keep the row picks
  its own fallback (`"agent"` in the name migration) and a caller that is
  validating input lets the emptiness fail the changeset.

  `nil` stays `nil` — a changeset with no username is not a username of `""`.
  """
  @spec sanitize(String.t() | nil) :: String.t() | nil
  def sanitize(nil), do: nil

  def sanitize(name) when is_binary(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(@combining_marks, "")
    |> String.downcase()
    |> String.replace(@unsafe_run, "-")
    |> String.trim("-")
  end
end
