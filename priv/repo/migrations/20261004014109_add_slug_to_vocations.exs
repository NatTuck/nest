defmodule Nest.Repo.Migrations.AddSlugToVocations do
  use Ecto.Migration

  import Ecto.Query

  # Self-contained slugify (mirrors `Nest.Slug.from_name/1` but is kept
  # local so this migration stays correct even if the shared helper
  # changes later). Lowercase, collapse non-alphanumerics to `-`, trim.
  def up do
    alter table(:vocations) do
      add :slug, :string
    end

    flush()

    backfill_slugs()

    alter table(:vocations) do
      modify :slug, :string, null: false
    end

    create unique_index(:vocations, [:slug])
  end

  def down do
    drop unique_index(:vocations, [:slug])

    alter table(:vocations) do
      remove :slug
    end
  end

  # Assign every row a slug derived from its name, disambiguating
  # collisions with a `-N` suffix (deterministic by id).
  defp backfill_slugs do
    taken = MapSet.new()

    repo().all(from(v in "vocations", select: {v.id, v.name}, order_by: v.id))
    |> Enum.reduce(taken, fn {id, name}, taken ->
      slug = unique_slug(slugify(name), taken)
      repo().update_all(from(v in "vocations", where: v.id == ^id), set: [slug: slug])
      MapSet.put(taken, slug)
    end)
  end

  defp unique_slug(base, taken) do
    if MapSet.member?(taken, base) do
      disambiguate(base, taken, 2)
    else
      base
    end
  end

  defp disambiguate(base, taken, n) do
    candidate = "#{base}-#{n}"

    if MapSet.member?(taken, candidate) do
      disambiguate(base, taken, n + 1)
    else
      candidate
    end
  end

  defp slugify(nil), do: "vocation"

  defp slugify(name) do
    case name
         |> String.downcase()
         |> String.replace(~r/[^a-z0-9]+/, "-")
         |> String.trim("-") do
      "" -> "vocation"
      slug -> slug
    end
  end
end
