defmodule Nest.Repo.Migrations.CreateVocations do
  use Ecto.Migration

  def change do
    create table(:vocations) do
      add :name, :string
      add :description, :string
      add :system_prompt, :text
      add :tools, :map
      add :modes, :map

      timestamps(type: :utc_datetime)
    end
  end
end
