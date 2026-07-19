defmodule Nest.Repo.Migrations.AddCloneAgentToVocations do
  @moduledoc """
  Backfill: ensure every existing row in `vocations` includes
  `"clone_agent"` in its `tools` array.

  The `clone_agent` tool is the runtime entry point for
  sub-agent delegation. New vocations seeded via
  `priv/repo/seeds.exs` already list it; this migration
  catches up pre-existing rows so a fresh database doesn't
  start without delegation enabled.

  Idempotent: re-running the migration is a no-op because
  the WHERE clause filters out rows that already carry
  the entry.

  ## Forward-only

  No schema change. The `vocations.tools` column was
  already an array of strings when sub-agent support was
  introduced; this migration only updates existing rows.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE vocations
    SET tools = array_append(tools, 'clone_agent'),
        updated_at = NOW()
    WHERE NOT ('clone_agent' = ANY(tools))
    """)
  end

  def down do
    execute("""
    UPDATE vocations
    SET tools = array_remove(tools, 'clone_agent'),
        updated_at = NOW()
    WHERE 'clone_agent' = ANY(tools)
    """)
  end
end
