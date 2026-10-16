defmodule Nest.Spaces.Space do
  # The list and the default live in `Nest.Sandbox.Backend`, the module that
  # dispatches on them; this schema reads them rather than owning a second copy.
  # Declared as an attribute before the `@moduledoc` because the moduledoc
  # interpolates both.
  @sandbox_backends Nest.Sandbox.Backend.backends()
  @default_sandbox_backend Nest.Sandbox.Backend.default()

  @moduledoc """
  Ecto schema for the `spaces` table.

  A Space is a container for a group of collaborating agents
  and their shared environment. Every agent belongs to exactly
  one space.

  ## Identity

  * `id` — server-internal `bigserial`. FK target for `agents.space_id`.
  * `name` — human-readable space name. Globally unique.
  * `slug` — URL-safe identifier derived from `name`. Globally unique.

  ## Multi-user

  * `created_by_user_id` — FK to `users.id`. The user who created
    the space.

  ## Sandbox backend

  * `sandbox_backend` — how this space's agents are sandboxed:
    `#{inspect(@sandbox_backends)}` (see `Nest.Sandbox.Backend`). It is chosen
    **once, at creation**:
    `create_changeset/2` sets it and `changeset/2` (the update path)
    deliberately cannot change it, because swapping a backend means
    replacing the environment the space's agents run in — not a live
    edit. `#{@default_sandbox_backend}` is the default, so every
    pre-existing row is a bwrap space.

    `"bwrap"` runs commands under bubblewrap and enforces the mode's
    caps. `"docker"` runs them in a container the space shares, which sees
    the workspace and the explicit `.nest` mounts and nothing else of the
    host. `"none"` runs the bare command on the host, so **caps cannot be
    enforced** for that space. See `Nest.Sandbox.Backend`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Nest.Agents.PersistedAgent
  alias Nest.Slug

  # `Nest.Spaces` names a space's root agent `<slug>-root` (see
  # `Nest.Spaces.root_agent_name/2`), and an agent's name is also its
  # scratch-directory segment, so the slug has to satisfy
  # `PersistedAgent`'s filename-safe rule *with room for this suffix*.
  # Kept here, next to the changeset that enforces it, and exposed so the
  # name builder and the rule cannot drift apart.
  @root_agent_suffix "-root"

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :blueprint_id,
             :workspace_path,
             :sandbox_backend,
             :created_by_user_id,
             :archived,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :id, autogenerate: true}
  schema "spaces" do
    field :name, :string
    field :slug, :string
    field :blueprint_id, :integer
    field :workspace_path, :string
    field :sandbox_backend, :string, default: @default_sandbox_backend
    field :created_by_user_id, :integer

    # Lifecycle. `archived` soft-hides the space from the main
    # space list (`Spaces.list_for_user/1`) and stops its agents.
    # The row and its agents are preserved so the owner can
    # inspect and unarchive it via the archived-spaces view.
    field :archived, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc """
  Build the changeset for **updating** a space row (rename).

  Required: `:name`, `:created_by_user_id`. `:slug` is derived
  from `:name` if not provided. `:blueprint_id` and
  `:workspace_path` are optional.

  `:sandbox_backend` is deliberately absent from the cast list: it is a
  creation-only choice (see `create_changeset/2`), so no update can move
  a space between backends.

  `:slug` must be usable as the root agent's name (`<slug>-root`), so it
  is held to `PersistedAgent`'s filename-safe rule. A client-supplied
  slug that isn't would otherwise fail later, as an `invalid_agent_name`
  error about a field the client never sent — see
  `NestWeb.LobbyChannel.AgentErrors.create_payload/1`.
  """
  def changeset(source, params) do
    source
    |> cast(params, [:name, :slug, :blueprint_id, :workspace_path, :created_by_user_id])
    |> validate_required([:name])
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> validate_slug()
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:blueprint_id)
  end

  @doc """
  Build the changeset for **inserting** a space row: `changeset/2` plus the
  creation-only `:sandbox_backend`.

  An absent or blank backend takes `Nest.Sandbox.Backend.default/0`; anything
  outside `Nest.Sandbox.Backend.backends/0` is refused with an error on the
  field, so a client cannot introduce a backend this build does not implement.
  """
  def create_changeset(source, params) do
    params = Map.put(params, :sandbox_backend, sandbox_backend_param(params))

    source
    |> changeset(params)
    |> cast(params, [:sandbox_backend])
    |> validate_required([:sandbox_backend])
    |> validate_inclusion(:sandbox_backend, @sandbox_backends,
      message: "must be one of #{Enum.join(@sandbox_backends, ", ")}"
    )
  end

  # The backend the caller asked for, from either key shape, falling back to
  # the default only when neither names one. A blank counts as absent: the New
  # Space form sends `nil` when the user leaves the picker alone, and `cast/4`
  # would otherwise write that `nil` through and fail `validate_required/2` on a
  # value the client never chose. An *unknown* value is passed through
  # unchanged, so `validate_inclusion/3` refuses it by name rather than the
  # default quietly replacing it.
  defp sandbox_backend_param(params) do
    [:sandbox_backend, "sandbox_backend"]
    |> Enum.map(&Map.get(params, &1))
    |> Enum.find(&present?/1)
    |> Kernel.||(@default_sandbox_backend)
  end

  defp present?(value), do: value not in [nil, ""]

  @doc """
  The suffix `Nest.Spaces` appends to a space's slug to name its root agent.
  """
  @spec root_agent_suffix() :: String.t()
  def root_agent_suffix, do: @root_agent_suffix

  # The slug becomes the root agent's name, so validate the *derived* name
  # rather than the slug: the rule (and the byte cap the suffix eats into)
  # belongs to the agent-name boundary, not to the slug's own shape.
  # `Slug.from_name/1` always produces a safe slug, so this only ever
  # rejects a client-supplied one.
  defp validate_slug(changeset) do
    validate_change(changeset, :slug, fn :slug, slug ->
      if PersistedAgent.valid_name?(slug <> @root_agent_suffix) do
        []
      else
        [slug: "must be usable as an agent name (letters, digits, `_` and `-`)"]
      end
    end)
  end

  # Generate a slug from `:name` when the caller didn't supply
  # one. Runs after `validate_required([:name])` so we always
  # have a name to slugify. We deliberately skip the
  # `valid?: true` guard here because the *next* step is
  # `validate_required([:slug])` — the slug we generate makes
  # that validation pass. The `valid?` flag stays false until
  # the trailing validations run.
  defp maybe_generate_slug(%Ecto.Changeset{} = changeset) do
    case fetch_change(changeset, :slug) do
      {:ok, slug} when is_binary(slug) and slug != "" ->
        changeset

      _ ->
        case fetch_change(changeset, :name) do
          {:ok, name} when is_binary(name) ->
            put_change(changeset, :slug, Slug.from_name(name))

          _ ->
            changeset
        end
    end
  end
end
