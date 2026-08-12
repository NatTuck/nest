defmodule Nest.Blueprints do
  @moduledoc """
  Context for blueprint CRUD operations.

  Blueprints are read-mostly templates: seeded at deploy
  time, queried by slug/ID at space-creation time, and
  rarely mutated after that. The mutation entry points
  exist for completeness but the seed script and admin
  tooling are the primary writers.

  ## Phase 2 vs. Phase 3

  Phase 2 (this module) ships:
    * The `blueprints` table + schema + CRUD
    * `Nest.Spaces.create_space_with_root_agent/2` reads
      the blueprint's `root_vocation_id` when a `blueprint_id`
      is supplied
    * The seed script provisions three blueprints

  Phase 3 will add:
    * `agents/spawn` enforcing `spawnable_vocation_ids`
    * `workspace_template` seeding into the root agent's
      workspace

  Those columns exist now (the migration adds them) so
  Phase 3 doesn't need a schema migration.
  """

  import Ecto.Query, warn: false

  alias Nest.Blueprints.Blueprint
  alias Nest.Repo

  @doc """
  List every blueprint, ordered by name. Used by the
  Phase 4 blueprint picker.
  """
  @spec list_blueprints() :: [Blueprint.t()]
  def list_blueprints do
    from(b in Blueprint, order_by: [asc: b.name])
    |> Repo.all()
  end

  @doc """
  Get a blueprint by its integer id. Returns `%Blueprint{}`
  or `nil`.
  """
  @spec get_blueprint(integer()) :: Blueprint.t() | nil
  def get_blueprint(id) when is_integer(id) do
    Repo.get(Blueprint, id)
  end

  @doc """
  Get a blueprint by its slug. Returns `%Blueprint{}` or
  `nil`.
  """
  @spec get_by_slug(String.t()) :: Blueprint.t() | nil
  def get_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Blueprint, slug: slug)
  end

  @doc """
  Insert a new blueprint row.

  ## Parameters

  * `attrs` — map with `:name` (required), `:slug`
    (optional; derived from `:name`), `:root_vocation_id`
    (required), `:description`, `:spawnable_vocation_ids`,
    `:workspace_template`, `:main_view_config` (all
    optional).

  ## Returns

  * `{:ok, %Blueprint{}}` on success
  * `{:error, %Ecto.Changeset{}}` on validation failure
  """
  @spec create_blueprint(map()) :: {:ok, Blueprint.t()} | {:error, Ecto.Changeset.t()}
  def create_blueprint(attrs) when is_map(attrs) do
    %Blueprint{}
    |> Blueprint.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a blueprint row in place.
  """
  @spec update_blueprint(Blueprint.t(), map()) ::
          {:ok, Blueprint.t()} | {:error, Ecto.Changeset.t()}
  def update_blueprint(%Blueprint{} = blueprint, attrs) when is_map(attrs) do
    blueprint
    |> Blueprint.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Upsert a blueprint by `name`. Idempotent: re-running with
  the same name updates the row in place.

  Used by the seed script so it can be re-run safely.
  """
  @spec upsert_blueprint(map()) :: {:ok, Blueprint.t()} | {:error, Ecto.Changeset.t()}
  def upsert_blueprint(attrs) when is_map(attrs) do
    case Repo.get_by(Blueprint, name: Map.fetch!(attrs, :name)) do
      nil -> create_blueprint(attrs)
      %Blueprint{} = existing -> update_blueprint(existing, attrs)
    end
  end

  @doc """
  Delete a blueprint. Spaces with this blueprint will have
  their `blueprint_id` nullified by the FK's
  `on_delete: :nilify_all` rule.
  """
  @spec delete_blueprint(Blueprint.t() | integer()) ::
          {:ok, Blueprint.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def delete_blueprint(%Blueprint{} = blueprint) do
    Repo.delete(blueprint)
  end

  def delete_blueprint(id) when is_integer(id) do
    case get_blueprint(id) do
      nil -> {:error, :not_found}
      %Blueprint{} = blueprint -> Repo.delete(blueprint)
    end
  end

  @doc """
  Resolve a blueprint by id, returning the integer
  `root_vocation_id` or `nil` when the blueprint is nil
  or missing.

  `Nest.Spaces.create_space_with_root_agent/2` uses this
  to translate a caller-supplied `blueprint_id` into the
  root agent's vocation. Returning `nil` (not raising) on
  missing matches `Vocations.get_vocation/1`'s contract.
  """
  @spec root_vocation_id_for(integer() | nil) :: integer() | nil
  def root_vocation_id_for(nil), do: nil

  def root_vocation_id_for(blueprint_id) when is_integer(blueprint_id) do
    case get_blueprint(blueprint_id) do
      nil -> nil
      %Blueprint{root_vocation_id: vid} -> vid
    end
  end

  @doc """
  Resolve a blueprint's spawnable-vocation whitelist by
  `blueprint_id`.

  Returns `nil` when the blueprint is nil or missing, and the
  (possibly empty) `spawnable_vocation_ids` list otherwise.

  `nil` and `[]` both mean **unrestricted**: `agents/spawn` allows
  any vocation. A non-empty list is a strict whitelist.

  `Spaces.spawnable_vocation_ids_for_space/1` is the space-level
  convenience that first resolves the space's `blueprint_id`.
  """
  @spec spawnable_vocation_ids(integer() | nil) :: [integer()] | nil
  def spawnable_vocation_ids(nil), do: nil

  def spawnable_vocation_ids(blueprint_id) when is_integer(blueprint_id) do
    case get_blueprint(blueprint_id) do
      nil -> nil
      %Blueprint{spawnable_vocation_ids: ids} -> ids || []
    end
  end
end
