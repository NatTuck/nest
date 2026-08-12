defmodule Nest.Repo.Migrations.AddArchivedToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :archived, :boolean, default: false, null: false
    end
  end
end
