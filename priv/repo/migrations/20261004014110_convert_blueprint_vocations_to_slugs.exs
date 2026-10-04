defmodule Nest.Repo.Migrations.ConvertBlueprintVocationsToSlugs do
  use Ecto.Migration

  import Ecto.Query

  # `blueprints` moves from integer vocation ids to vocation slugs, so
  # blueprints and the spawn interface speak the same language.
  def up do
    alter table(:blueprints) do
      add :root_vocation, :string
      add :spawnable_vocations, {:array, :string}, default: []
    end

    flush()

    slug_by_id = Map.new(repo().all(from(v in "vocations", select: {v.id, v.slug})))

    for {id, root_id, spawn_ids} <- old_blueprints() do
      root_slug = Map.get(slug_by_id, root_id)

      spawn_slugs =
        (spawn_ids || [])
        |> Enum.map(&Map.get(slug_by_id, &1))
        |> Enum.reject(&is_nil/1)

      update_blueprint(id, root_vocation: root_slug, spawnable_vocations: spawn_slugs)
    end

    alter table(:blueprints) do
      modify :root_vocation, :string, null: false
      remove :root_vocation_id
      remove :spawnable_vocation_ids
    end
  end

  def down do
    alter table(:blueprints) do
      add :root_vocation_id, :integer
      add :spawnable_vocation_ids, {:array, :integer}, default: []
    end

    flush()

    id_by_slug = Map.new(repo().all(from(v in "vocations", select: {v.slug, v.id})))

    for {id, root_slug, spawn_slugs} <- new_blueprints() do
      root_id = Map.get(id_by_slug, root_slug)

      spawn_ids =
        (spawn_slugs || [])
        |> Enum.map(&Map.get(id_by_slug, &1))
        |> Enum.reject(&is_nil/1)

      update_blueprint(id, root_vocation_id: root_id, spawnable_vocation_ids: spawn_ids)
    end

    alter table(:blueprints) do
      remove :root_vocation
      remove :spawnable_vocations
    end
  end

  # Before the swap: read the legacy integer columns.
  defp old_blueprints do
    repo().all(
      from(b in "blueprints",
        select: {b.id, b.root_vocation_id, b.spawnable_vocation_ids}
      )
    )
  end

  # After the swap (down path): read the slug columns.
  defp new_blueprints do
    repo().all(
      from(b in "blueprints",
        select: {b.id, b.root_vocation, b.spawnable_vocations}
      )
    )
  end

  defp update_blueprint(id, sets) do
    repo().update_all(from(b in "blueprints", where: b.id == ^id), set: sets)
  end
end
