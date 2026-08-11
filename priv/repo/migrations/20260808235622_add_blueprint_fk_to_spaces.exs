defmodule Nest.Repo.Migrations.AddBlueprintFkToSpaces do
  @moduledoc """
  Add the foreign key constraint from `spaces.blueprint_id`
  to `blueprints.id`.

  Until now `spaces.blueprint_id` was a bare integer column
  added speculatively by `CreateSpaces`. This migration
  promotes it to a real FK with `on_delete: :nilify_all` so
  dropping a blueprint detaches the spaces without losing
  the space rows.
  """

  use Ecto.Migration

  def change do
    alter table(:spaces) do
      modify :blueprint_id,
             references(:blueprints, on_delete: :nilify_all),
             from: :integer
    end
  end
end
