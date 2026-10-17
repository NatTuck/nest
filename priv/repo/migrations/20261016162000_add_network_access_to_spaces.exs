defmodule Nest.Repo.Migrations.AddNetworkAccessToSpaces do
  use Ecto.Migration

  # Network access is a *space* property from here on: it used to live in each
  # vocation mode's caps, so an existing space's value is what its agents
  # effectively had — `true` iff any mode of the space's root agent's vocation
  # enabled it, and `false` when there is no root agent, no vocation, or no modes
  # (which is what `Nest.Sandbox.default_caps/0` falls back to).
  #
  # The derivation is a pure function of the tables, so running it twice changes
  # nothing.
  @root_agent "a.parent_id IS NULL"

  # The derivation, as SQL. Public so the test can run it against fixture rows:
  # the JSONB walk and the root-agent join are the risky part of this migration,
  # and a migration that has already run in the test database cannot be re-run.
  @doc false
  @spec network_access_sql() :: String.t()
  def network_access_sql do
    """
    UPDATE spaces s
       SET network_access = COALESCE((
             SELECT bool_or((mode.value -> 'caps' ->> 'net')::boolean)
               FROM agents a
               JOIN vocations v ON v.id = a.vocation_id
               CROSS JOIN LATERAL jsonb_each(v.modes) AS mode(key, value)
              WHERE a.space_id = s.id
                AND #{@root_agent}
           ), false)
    """
  end

  def up do
    alter table(:spaces) do
      add :network_access, :boolean, null: false, default: true
    end

    # The column's `default: true` is what a *new* space gets. Existing rows have
    # to be derived from their agents, and the query below needs the column to
    # exist first.
    flush()

    execute(network_access_sql())
  end

  def down do
    alter table(:spaces) do
      remove :network_access
    end
  end
end
