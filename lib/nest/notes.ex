defmodule Nest.Notes do
  @moduledoc """
  The context for `user_notes`: every note with a **human at one end**.

  Three words, one job each (`notes/space-chat.md`): a **message** is a row in
  `messages` — what an LLM sees; a **note** is the transport unit — sender,
  recipient, kind, content; a **notice** is a marker on the runtime's text, not
  a thing. A note to an *agent* is the inbox's (`Nest.Agents.Agent.Inbox`): it
  queues, drains and becomes a message. A note to a *human* has none of that —
  no process, no inbox, no transcript — so it is a row here and a frame on the
  space's topic.

  ## Addressed, not mailbox-owned

  A row names both ends: `from_kind`/`from_name`/`to_kind`/`to_name`. There is
  no owning `user_id`, which is what makes a note between two humans **one row
  both of them read** rather than two mirrors of it. The sigil never enters a
  column: `to_name` is the bare name and `to_kind` says whether it is a human or
  an agent, because a human `nat` and an agent `nat` are different addressees.

  ## One end is human

  The table only holds rows with a human at one end — enforced by the
  `:one_end_is_human` check constraint, not by convention. Agent-to-agent notes
  are the inbox's, and a copy here would be a second spelling of what an agent
  was told.

  ## An address names a user

  `deliver/5`'s `:user` addressee is resolved with
  `Nest.Accounts.get_user_by_username/1`: an address names a *user*, and a
  username that names nobody is `{:error, :not_found}` — the refusal the send
  tools report as "No human `@bob`." `human?/1` is that rule as a question, so
  the send tools, the wait and this module cannot disagree about who an address
  reaches.

  **Discovery and resolution are two different questions**, and this is where
  they differ. Resolution asks "does this address reach somebody" and answers
  for any user. Discovery asks "who is in this space", and there is **no
  membership table** to answer it with: a space has one owner
  (`spaces.created_by_user_id`, `notes/multiple-users.md`), so
  `list_humans_for_space/1` names that owner — the human an agent in the space
  is told about. A note to a user who is not in the space is therefore still a
  row: the table is addressed, and *membership* is what will decide who may read
  it once a space can hold more than one human. Inventing a membership gate here
  would be a second, weaker copy of the one the feed will need.

  ## `answered_at`

  Set when the human **sends a note back to that agent** (`mark_answered/3`),
  which is the advisory banner's clear. The cheaper candidate trigger — "any
  note from that agent to the human" — is wrong: it clears the banner on a note
  that answered something else. Only a `:query` row is answered by it, and only
  one still outstanding.

  ## The feed

  `list_for/2` is "rows in this space where I am one end", ordered by `id` —
  the table's `id` is monotonic, so it is the order and `inserted_at` is for
  display only. Two predicates, one index each (`space_id, to_kind, to_name,
  id` and `space_id, from_kind, from_name, id`), so the OR needs no sort.

  Every row this module writes broadcasts `{:user_note, %UserNote{}}` on the
  space's topic (`Nest.Agents.Agent.Broadcasts.space_topic/1`). `answered_at`
  does **not** broadcast: it is the human's own action on their own query, and
  the banner is advisory — the feed's read is the authority.
  """

  import Ecto.Query

  alias Nest.Accounts
  alias Nest.Accounts.User
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Notes.UserNote
  alias Nest.Persistence
  alias Nest.Repo
  alias Nest.Spaces.Space

  @typedoc """
  Who a note is from: an agent's name, a human's username, or `:runtime` with
  the name of the agent the runtime is speaking about.
  """
  @type from :: {:agent, String.t()} | {:user, String.t()} | {:runtime, String.t()}

  @typedoc "Who a note is addressed to. The runtime has no address."
  @type to :: {:agent, String.t()} | {:user, String.t()}

  @doc """
  Persist one note and broadcast it.

  `from` is a `t:from/0` and `to` a `t:to/0`; `kind` is the note's kind
  (`t:Nest.Notes.UserNote.kind/0`), and `content` is the body **as written** —
  no header, no marker (a header is what a *message* carries, and a note is not
  a message).

  Returns `{:ok, note}` — the row, already broadcast — or:

    * `{:error, :not_found}` when the addressee is a human address that names
      no user;
    * `{:error, changeset}` for a row the database refuses. The reachable one is
      an **agent-to-agent** note, which is the inbox's: the `:one_end_is_human`
      check constraint refuses it here rather than letting a second spelling of
      what an agent was told into the table. A missing space is the other.
  """
  @spec deliver(integer(), from(), to(), String.t(), UserNote.kind()) ::
          {:ok, UserNote.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def deliver(space_id, from, to, content, kind) do
    with {:ok, from_kind, from_name} <- sender(from),
         {:ok, to_kind, to_name} <- addressee(to) do
      insert(space_id, from_kind, from_name, to_kind, to_name, content, kind)
    end
  end

  @doc """
  The notes in `space_id` that `{:user, username}` is one end of, oldest first.

  Both directions in one read: the notes addressed to that human (`to_kind:
  :user`) and the ones they sent (`from_kind: :user`) — which is what makes a
  note between two humans one row that appears in both of their feeds. Ordered
  by `id`, the table's monotonic key, so the two index scans need no sort.

  This is the SQL form of `for_user?/2`, which asks the same question about one
  row (a broadcast's). They are one rule in two execution contexts and must move
  together.
  """
  @spec list_for(integer(), {:user, String.t()}) :: [UserNote.t()]
  def list_for(space_id, {:user, username}) do
    from(n in UserNote,
      where: n.space_id == ^space_id,
      where:
        (n.to_kind == :user and n.to_name == ^username) or
          (n.from_kind == :user and n.from_name == ^username),
      order_by: [asc: n.id]
    )
    |> Repo.all()
  end

  @doc """
  Whether `{:user, username}` is one end of `note` — `list_for/2`'s rule, asked
  about one row.

  The two must agree, and this is the one that can be asked of a row a broadcast
  handed us: the space's topic reaches every session of every human in the
  space, so "in this space" is not enough to decide who may see a note. A note
  between two other humans is in the space and is none of this human's business,
  which is why the feed's push applies the same predicate as its read rather
  than only the space.
  """
  @spec for_user?(UserNote.t(), {:user, String.t()}) :: boolean()
  def for_user?(%UserNote{to_kind: :user, to_name: name}, {:user, name}), do: true
  def for_user?(%UserNote{from_kind: :user, from_name: name}, {:user, name}), do: true
  def for_user?(%UserNote{}, {:user, _username}), do: false

  @doc """
  The usernames of the humans in `space_id`, oldest account first.

  A space has one owner and no membership table (`notes/multiple-users.md`), so
  this is the owner — the human an agent in the space is told about, and the one
  whose feed the space's notes appear in. It is a list because the *shape* is
  "the space's humans": when a space can hold several, this is the one function
  that grows, and both the `agents-list` line and any future recipient picker
  read it from here.
  """
  @spec list_humans_for_space(integer()) :: [String.t()]
  def list_humans_for_space(space_id) do
    from(s in Space,
      join: u in User,
      on: u.id == s.created_by_user_id,
      where: s.id == ^space_id,
      where: not is_nil(u.username),
      order_by: [asc: u.id],
      select: u.username
    )
    |> Repo.all()
  end

  @doc """
  Whether `username` is a human an address can reach — a real user.

  The one resolution rule: `deliver/5` gates on it, the send tools' refusals
  agree with it (`Nest.Agents.target_error/2`), and `agents-wait` treats an
  address that passes as a human it must not wait for. It is a *user*, not a
  membership — see the moduledoc for why there is no membership check.
  """
  @spec human?(String.t()) :: boolean()
  def human?(username), do: Accounts.get_user_by_username(username) != nil

  @doc """
  Mark the queries `agent_name` sent `username` as answered.

  The human sent a note back to that agent, which is what answers the queries it
  sent them: every outstanding (`answered_at` null) `:query` row from that agent
  to that human in this space gets the same timestamp. A plain `:agent` note
  answers nothing — only a `:query` was waiting for an answer — and a note back
  to a *different* agent answers only that agent's queries.
  """
  @spec mark_answered(integer(), String.t(), String.t()) :: :ok
  def mark_answered(space_id, username, agent_name) do
    from(n in UserNote,
      where: n.space_id == ^space_id,
      where: n.kind == :query,
      where: n.to_kind == :user and n.to_name == ^username,
      where: n.from_kind == :agent and n.from_name == ^agent_name,
      where: is_nil(n.answered_at)
    )
    |> Repo.update_all(set: [answered_at: Persistence.now()])

    :ok
  end

  # ---- private ----

  # A sender's columns. The runtime arm keeps the *agent's* name in `from_name`
  # so a give-up still reads `[From nest runtime]` (the kind says the runtime
  # spoke) while the feed can group it by the agent that did not answer.
  defp sender({:runtime, agent_name}), do: {:ok, :runtime, agent_name}
  defp sender({:user, username}), do: {:ok, :user, username}
  defp sender({:agent, name}), do: {:ok, :agent, name}

  # A recipient's columns. Only a human has to be resolved: an agent was found
  # by the caller (`Nest.Agents.Supervisor`), and an address that names no user
  # is the `:not_found` every tool already knows how to word.
  defp addressee({:user, username}) do
    if human?(username), do: {:ok, :user, username}, else: {:error, :not_found}
  end

  defp addressee({:agent, name}), do: {:ok, :agent, name}

  defp insert(space_id, from_kind, from_name, to_kind, to_name, content, kind) do
    %UserNote{}
    |> UserNote.changeset(%{
      space_id: space_id,
      from_kind: from_kind,
      from_name: from_name,
      to_kind: to_kind,
      to_name: to_name,
      content: content,
      kind: kind
    })
    |> Repo.insert()
    |> case do
      {:ok, note} ->
        broadcast(note)
        {:ok, note}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # One frame per note, on the space's topic, carrying the row: the feed is one
  # table, so the row it will read is exactly what a client needs to add.
  defp broadcast(note) do
    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      Broadcasts.space_topic(note.space_id),
      {:user_note, note}
    )
  end
end
