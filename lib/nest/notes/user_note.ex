defmodule Nest.Notes.UserNote do
  @moduledoc """
  Ecto schema for the `user_notes` table: one note with a **human at one end**.

  See `Nest.Notes` for the context and `notes/space-chat.md` for the design.
  The row is *addressed* — a sender and a recipient, both named — rather than
  mailbox-owned, which is what makes a note between two humans one row both of
  them read.

  ## The four "kinds"

  `from_kind`/`to_kind` answer *who*, and they are why the names beside them are
  not enough on their own: a human `nat` and an agent `nat` are different
  addressees, and the sigil never enters a column.

    * `from_kind` — `:agent` (an agent's words), `:user` (a human's) or
      `:runtime` (the runtime speaking about the agent in `from_name`, so a
      give-up still reads `[From nest runtime]` while the feed can group it by
      the agent that did not answer);
    * `to_kind` — `:agent` or `:user`. Never `:runtime`: the runtime has no
      address.

  `kind` answers *what kind of note*, in the same vocabulary an inbox entry
  uses: `:query` obliges an answer (the advisory banner reads incoming queries
  whose `answered_at` is null), `:agent` is a plain note, `:runtime` is the
  runtime speaking.

  ## Timestamps

  `inserted_at` only — a note's body never changes, and the one write after
  insert is `answered_at`, which is set when the human sends a note back to the
  agent that queried them. There is deliberately no `read_at`: per-item read
  tracking has no UI behind it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @from_kinds [:agent, :user, :runtime]
  @to_kinds [:agent, :user]
  @kinds [:query, :agent, :runtime]

  @derive {Jason.Encoder,
           only: [
             :id,
             :space_id,
             :from_kind,
             :from_name,
             :to_kind,
             :to_name,
             :content,
             :kind,
             :inserted_at,
             :answered_at
           ]}

  @type t :: %__MODULE__{
          id: integer() | nil,
          space_id: integer() | nil,
          from_kind: from_kind() | nil,
          from_name: String.t() | nil,
          to_kind: to_kind() | nil,
          to_name: String.t() | nil,
          content: String.t() | nil,
          kind: kind() | nil,
          inserted_at: DateTime.t() | nil,
          answered_at: DateTime.t() | nil
        }

  @typedoc "Who a note is from: an agent, a human, or the runtime about an agent."
  @type from_kind :: :agent | :user | :runtime

  @typedoc "Who a note is addressed to. The runtime has no address."
  @type to_kind :: :agent | :user

  @typedoc "What kind of note it is: a query, a plain note, or the runtime's words."
  @type kind :: :query | :agent | :runtime

  schema "user_notes" do
    field :space_id, :integer
    field :from_kind, Ecto.Enum, values: @from_kinds
    field :from_name, :string
    field :to_kind, Ecto.Enum, values: @to_kinds
    field :to_name, :string
    field :content, :string
    field :kind, Ecto.Enum, values: @kinds
    field :answered_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Build the changeset for inserting a note.

  `Ecto.Enum` is what validates `from_kind`/`to_kind`/`kind`: a value outside
  the three vocabularies is a cast error on the field rather than a string
  nothing can read. The one end that must be human is the table's check
  constraint (`:one_end_is_human`), surfaced here so a bad row is a changeset
  error and not a raise.
  """
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(source, params) do
    source
    |> cast(params, [
      :space_id,
      :from_kind,
      :from_name,
      :to_kind,
      :to_name,
      :content,
      :kind,
      :answered_at
    ])
    |> validate_required([:space_id, :from_kind, :to_kind, :to_name, :content, :kind])
    |> foreign_key_constraint(:space_id)
    |> check_constraint(:to_kind,
      name: :one_end_is_human,
      message: "a note must have a human at one end"
    )
  end
end
