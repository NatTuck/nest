defmodule Nest.Blueprints.Blueprint do
  @moduledoc """
  Ecto schema for the `blueprints` table.

  A Blueprint is a template for creating a Space: it pins
  the root agent's vocation, names the sub-agent vocations
  the space's agents are allowed to spawn, seeds a workspace
  template, and drives the Main View layout.

  ## Identity

  * `id` — server-internal `bigserial`. FK target for
    `spaces.blueprint_id`.
  * `name` — human-readable blueprint name. Globally unique.
  * `slug` — URL-safe identifier derived from `name`. Globally
    unique.

  ## Shape

  * `root_vocation` — the **slug** of the root agent's vocation
    when a space is created from this blueprint. Always set.
  * `spawnable_vocations` — whitelist of vocation **slugs** the
    space's agents are allowed to spawn via the `agents-spawn`
    tool. `[]` (or `nil`) means **unrestricted** — any
    vocation may be spawned. A non-empty list is a strict
    whitelist; `agents-spawn` rejects vocations outside it.
    A space without a blueprint (or with a missing blueprint)
    is also unrestricted.
  * `default_net` — the `network_access` a space created from
    this blueprint starts with, when the caller names none
    (`Nest.Spaces.create_space/2`). A default rather than a
    policy: the value is editable afterwards, and a caller that
    names one wins. `NOT NULL`, so every blueprint has an
    opinion.
  * `default_spawnable_vocation` — the vocation **slug** an
    `agents-spawn`/`agents-batch` call gets when the model omits
    `vocation`. `nil` is a real answer, not a missing one: it
    means this blueprint does not say, and the spawn is refused
    with an error naming the missing argument rather than
    falling back to the caller's own vocation. When set, it must
    be a slug the space may spawn — see
    `validate_default_spawnable_vocation/1`.
  * `workspace_template` — map of initial workspace files.
    Seeding is deferred; the column exists for future use.
  * `main_view_config` — map consumed by the Phase 4 Main
    View component to pick the layout. Empty by default.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Nest.Slug

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :slug,
             :description,
             :root_vocation,
             :spawnable_vocations,
             :default_mode,
             :default_net,
             :default_spawnable_vocation,
             :workspace_template,
             :main_view_config,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :id, autogenerate: true}
  schema "blueprints" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :root_vocation, :string
    field :spawnable_vocations, {:array, :string}, default: []

    # The mode a new agent in a space using this blueprint starts in
    # (`Nest.Modes`). A blueprint is where the *defaults* live: the mode is a
    # per-agent property, but something has to say what an agent gets before
    # anything has said otherwise, and that is the blueprint the space names.
    field :default_mode, :string, default: "act"

    # The network access a space created from this blueprint starts with, when
    # the caller names none. `NOT NULL`: a blueprint always has an opinion, so
    # nothing has to treat "no value" as a third state.
    field :default_net, :boolean, default: true

    # The vocation an unnamed `agents-spawn`/`agents-batch` gets. `nil` means
    # "this blueprint does not say", which the spawn refuses rather than guessing
    # (see `Nest.Agents.Supervisor.resolve_spawn_vocation/2`).
    field :default_spawnable_vocation, :string

    field :workspace_template, :map, default: %{}
    field :main_view_config, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          slug: String.t() | nil,
          description: String.t() | nil,
          root_vocation: String.t() | nil,
          spawnable_vocations: [String.t()],
          default_mode: String.t() | nil,
          default_net: boolean() | nil,
          default_spawnable_vocation: String.t() | nil,
          workspace_template: map(),
          main_view_config: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc false
  def changeset(blueprint, params) do
    blueprint
    |> cast(params, [
      :name,
      :slug,
      :description,
      :root_vocation,
      :spawnable_vocations,
      :default_mode,
      :default_net,
      :default_spawnable_vocation,
      :workspace_template,
      :main_view_config
    ])
    |> validate_required([:name, :root_vocation])
    |> validate_change(:default_mode, &validate_default_mode/2)
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
    |> validate_spawnable_vocations()
    |> validate_default_spawnable_vocation()
  end

  # The default vocation has to be one this space may actually spawn, or
  # `agents-spawn` would refuse the very spawn the blueprint told the model to
  # make. The whitelist is read from the changeset's *resulting* value, because a
  # caller may set both in one changeset and validating against the stored list
  # would refuse a self-consistent pair.
  defp validate_default_spawnable_vocation(changeset) do
    case get_field(changeset, :default_spawnable_vocation) do
      slug when is_binary(slug) ->
        validate_default_against_whitelist(changeset, slug)

      # `nil` is how a blueprint says "I name no default" — a real answer rather
      # than a missing one, and also what `cast/3` makes of a blank string, so a
      # `""` default needs no clause of its own. A non-string never reaches this
      # validator at all: `cast/3` refuses it on type first ("is invalid"), and a
      # second message for the same mistake would help nobody.
      _no_default ->
        changeset
    end
  end

  # An empty whitelist is unrestricted (`[]` and `nil` both mean "anything"), so
  # any slug is allowed against it — matching `Nest.Agents.Supervisor`'s
  # `slug_allowed?/2`, which is the reader that has to agree with this.
  defp validate_default_against_whitelist(changeset, slug) do
    allowed = get_field(changeset, :spawnable_vocations) || []

    if allowed == [] or slug in allowed do
      changeset
    else
      add_error(
        changeset,
        :default_spawnable_vocation,
        "must be one of the spawnable vocations (#{Enum.join(allowed, ", ")})"
      )
    end
  end

  # A mode this build does not implement is refused here rather than stored and
  # resolved to something else when a space using this blueprint creates an
  # agent: `Nest.Modes.caps/1` falls back so a stale row still runs, but a row
  # should never *hold* a name nothing can honour.
  defp validate_default_mode(:default_mode, mode) do
    if Nest.Modes.valid?(mode) do
      []
    else
      [default_mode: "must be one of #{Enum.join(Nest.Modes.names(), ", ")}"]
    end
  end

  # Same slug auto-gen rule as `Space`: only generate when
  # the caller didn't supply one, and only after `:name`
  # has been validated.
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

  # Guards the spawnable-vocation whitelist shape (no dupes, all
  # entries non-empty strings) so seed data can't ship a malformed
  # list that would crash `agents-spawn` when it reads it.
  defp validate_spawnable_vocations(changeset) do
    case get_field(changeset, :spawnable_vocations) do
      nil ->
        changeset

      slugs when is_list(slugs) ->
        valid? =
          Enum.all?(slugs, &(is_binary(&1) and &1 != "")) and
            length(Enum.uniq(slugs)) == length(slugs)

        if valid? do
          changeset
        else
          add_error(changeset, :spawnable_vocations, "must be unique non-empty strings")
        end

      _other ->
        add_error(changeset, :spawnable_vocations, "must be a list of strings")
    end
  end
end
