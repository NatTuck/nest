defmodule Nest.Repo.Migrations.AddArchivedToSpaces do
  use Ecto.Migration

  def change do
    alter table(:spaces) do
      add :archived, :boolean, default: false, null: false
    end
  end
end
