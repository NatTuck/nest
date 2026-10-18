defmodule Nest.Repo.Migrations.AddSpaceNoticePendingToAgents do
  use Ecto.Migration

  # A space edit sets this on every agent in the space. A live agent is told by a
  # cast and clears it; one that is stopped cannot be told, so it keeps the flag
  # and announces the change on its next start (`Nest.Agents.Agent.Callbacks`).
  def change do
    alter table(:agents) do
      add :space_notice_pending, :boolean, null: false, default: false
    end
  end
end
