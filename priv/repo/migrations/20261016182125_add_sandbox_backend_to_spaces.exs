defmodule Nest.Repo.Migrations.AddSandboxBackendToSpaces do
  use Ecto.Migration

  def change do
    alter table(:spaces) do
      add :sandbox_backend, :string, default: "bwrap", null: false
    end
  end
end
