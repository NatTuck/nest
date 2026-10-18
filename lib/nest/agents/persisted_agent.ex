defmodule Nest.Agents.PersistedAgent do
  @moduledoc """
  Ecto schema for the `agents` table. One row per agent, keyed by
  a server-internal bigserial `id` (FK target) and a human-readable
  `name` (the identifier used everywhere outside the DB).

  The schema is the persistence-side mirror of the runtime
  `Nest.Agents.Agent` struct's identity fields (`name`, `vocation`,
  `model`, `next_message_index`). The full
  runtime state (tools, llm_metrics, chat_state, etc.) lives only
  in memory; the row is just enough to rehydrate the agent on
  restore.

  `vocation` is loaded from the DB at restore time via
  `Persistence.load_vocation/1` (the in-memory `Agent` carries the
  struct; the row carries the id only).

  The integer `id` is server-internal — callers read and write
  rows keyed by `name`; the FK joins use `agents.id`.

  ## Sub-agent tree

  `parent_id` is the integer `agents.id` of the agent that
  spawned this one via the `agents-spawn` tool (with
  `clone_context`) (nil for roots).
  `depth` is the agent's tree depth (0 for roots; `parent.depth
  + 1` for children). Both columns survive a BEAM restart so the
  agent's tree position is reconstructed on reload. The runtime
  supervisor cascades termination separately; the DB columns are
  the historical relationship only.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # An agent's `name` doubles as its scratch-directory segment:
  # `Nest.Agents.Agent.TmpSpace.agent_dir/3` joins it onto the space
  # directory, and `cleanup/3` `rm_rf`s that join. The rule is therefore a
  # filesystem one as well as a naming one, and it lives in `Nest.Name` — the
  # same rule `Nest.Accounts.User` applies to a human's username, so the two
  # cannot diverge:
  #
  #   * the pattern is `[a-z0-9_-]+`: no `/` (would nest), no `.` (a `..`
  #     component escapes the space dir), no whitespace, no control characters,
  #     and **no capitals** (`@Nat` and `@nat` are one address);
  #   * the cap is the filesystem component limit (`NAME_MAX`), 255 B, which is
  #     exact because the scratch segment is the bare name and the character
  #     class is ASCII-only.
  #
  # Enforced on insert and on any name change (a rename goes through this
  # changeset, so a name can never become unsafe). Existing rows that
  # predate the rule are rewritten by the name migrations
  # (`priv/repo/migrations/20261011000000_sanitize_agent_names.exs` and
  # `20261022000000_lowercase_names.exs`); the changeset never rewrites a name
  # itself.
  @name_format Nest.Name.pattern()
  @max_name_bytes Nest.Name.max_bytes()

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t(),
          space_id: integer() | nil,
          vocation_id: integer() | nil,
          model: map(),
          next_message_index: non_neg_integer(),
          last_compaction_index: integer(),
          fork_message_index: integer() | nil,
          parent_id: integer() | nil,
          depth: non_neg_integer(),
          created_by_user_id: integer() | nil,
          shared: boolean(),
          archived: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :id, autogenerate: true}
  schema "agents" do
    field :name, :string
    field :space_id, :integer
    field :vocation_id, :integer
    field :model, :map
    field :next_message_index, :integer, default: 0

    # The agent's mode (`Nest.Modes`): a per-agent runtime property, not a
    # per-vocation one. `null: false` with the permissive default, so a row
    # inserted by a caller that says nothing about a mode still has one — and so
    # that "the column is the truth" holds for every read path, including a
    # restart, which must not widen a child that was spawned read-only.
    field :mode, :string, default: "act"

    # Boundary pointer for the active/history partition of an
    # agent's messages. `state.chat_state.messages` is exactly
    # `messages WHERE message_index > agents.last_compaction_index`.
    # `-1` is the sentinel for "never compacted; everything,
    # including the system prompt at index 0, is in messages".
    # Bumped atomically by `Persistence.record_compaction/3`
    # together with the compaction marker INSERT.
    field :last_compaction_index, :integer, default: -1

    # Tree position. `parent_id` is the integer `agents.id` of
    # the agent that spawned this one (nil for roots). `depth`
    # is the agent's tree depth (0 for roots; `parent.depth +
    # 1` for children). The `belongs_to :parent` declaration
    # below keeps the FK in the schema (so the migration's
    # `references` is enforced) without exposing a `:parent`
    # association accessor — callers reach the parent via
    # `Persistence.fetch_agent/2` (looked up by `parent_id`,
    # not by name).
    field :parent_id, :integer
    field :depth, :integer, default: 0

    # Fork boundary for clones: the clone's first own
    # `message_index`. The clone shares its ancestors' rows below
    # this index and owns from it up (see
    # `notes/shared-message-structure.md`). `NULL` means the agent
    # owns its full sequence from index 0 (a root or a fresh child).
    field :fork_message_index, :integer

    belongs_to :parent, __MODULE__, foreign_key: :parent_id, define_field: false

    # Multi-user identity. `created_by_user_id` is the
    # integer `users.id` of the user who created the agent.
    # Nullable in the schema because rows created before
    # the multi-user migration landed have no owner; new
    # rows are inserted with the caller's id (see
    # `Agents.create_agent/2`).
    #
    # `shared` is the visibility flag. When `true`, every
    # authenticated user can see and chat with the agent
    # in the lobby; the owner still has edit/delete rights.
    # Default `false` keeps the privacy guarantee for new
    # agents created without an explicit `shared: true`
    # opt-in.
    field :created_by_user_id, :integer
    field :shared, :boolean, default: false

    # Lifecycle. `archived` marks an agent as stopped + hidden
    # from `agents-list` and the lobby sidebar. Archived rows
    # accumulate over time (fine for now; a cleanup/partitioning
    # story is future work). Archived agents are NOT excluded
    # from persisted message-history / parent-child joins.
    field :archived, :boolean, default: false

    # Set by `Nest.Spaces.update_environment/2` on every agent in the space. A
    # live agent is told immediately and clears it; a stopped one announces the
    # change when it next starts.
    field :space_notice_pending, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Build a changeset for inserting an agent row.

  Required: `:name` and `:model`. `:vocation_id`, `:parent_id`, and
  `:depth` are optional. `:next_message_index`
  defaults to 0 and is bumped on every persisted message via a
  separate UPDATE.

  `id` is autogenerated by the DB and is not cast here.

  `:name` must be a single filename-safe component
  (`#{@name_format.source}`) of at most `#{@max_name_bytes}` bytes — see the
  comment on those attributes.

  Accepts both atom-keyed and string-keyed params (callers
  from the test suite pass string keys; the Agent's runtime
  uses atom keys). String keys are normalized to atoms here.
  """
  def changeset(source, params) do
    params = atomize_keys(params)

    source
    |> cast(params, [
      :name,
      :space_id,
      :vocation_id,
      :model,
      :mode,
      :next_message_index,
      :last_compaction_index,
      :fork_message_index,
      :parent_id,
      :depth,
      :created_by_user_id,
      :shared,
      :archived
    ])
    |> validate_required([:name, :space_id, :model])
    # `count: :bytes` — the bound is the filesystem's, not the column's.
    # With `@name_format` enforced below, bytes == characters, so the two
    # limits coincide.
    |> validate_length(:name, min: 1, max: @max_name_bytes, count: :bytes)
    |> validate_format(:name, @name_format,
      message: "must contain only lowercase letters, digits, `_` and `-`"
    )
    |> unique_constraint([:space_id, :name])
    # Defensive: depth must be non-negative. The DB-side
    # CHECK constraint is the canonical guard; this one
    # surfaces the error as a changeset error instead of
    # letting the DB raise.
    |> validate_number(:depth, greater_than_or_equal_to: 0)
    |> validate_change(:mode, &validate_mode/2)
  end

  # A mode this build does not implement is refused at the boundary rather than
  # stored and resolved to something else on the way out: `Nest.Modes.caps/1`
  # falls back to the default so that a stale row still runs, but a row should
  # never *hold* a name nothing can honour.
  defp validate_mode(:mode, mode) do
    if Nest.Modes.valid?(mode) do
      []
    else
      [mode: "must be one of #{Enum.join(Nest.Modes.names(), ", ")}"]
    end
  end

  @doc """
  Whether `name` may be used verbatim as a scratch-directory segment:
  `#{@name_format.source}` — lowercase letters, digits, `_` and `-` only — at
  most `#{@max_name_bytes}` bytes.

  The rule is `Nest.Name.valid?/1`; this is the agent-side name for it, kept
  because an agent's `name` *is* the directory segment
  (`Nest.Agents.Agent.TmpSpace`) and this is where it is enforced at the DB
  boundary. It is exposed so a caller that *derives* a name from another field
  can apply the same rule at its own boundary instead of copying it:
  `Nest.Spaces.Space.changeset/2` refuses a client-supplied `:slug` whose
  `<slug>-root` root-agent name would fail it — otherwise the client gets an
  `invalid_agent_name` error naming a field it never sent (see
  `NestWeb.LobbyChannel.AgentErrors.create_payload/1`).
  """
  @spec valid_name?(term()) :: boolean()
  defdelegate valid_name?(name), to: Nest.Name, as: :valid?

  defp atomize_keys(params) when is_map(params) and not is_struct(params) do
    Map.new(params, fn {k, v} -> {if(is_binary(k), do: safe_atom(k), else: k), v} end)
  end

  defp atomize_keys(other), do: other

  # Convert a string key to an atom, falling back to the
  # original string if the atom doesn't exist (e.g. for
  # unknown keys from a future caller).
  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
