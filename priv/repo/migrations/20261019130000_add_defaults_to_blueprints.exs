defmodule Nest.Repo.Migrations.AddDefaultsToBlueprints do
  use Ecto.Migration

  # A blueprint is where a space's *defaults* live, so the two properties a space
  # inherits from it when the caller names nothing belong here rather than being
  # hardcoded at the call sites.
  #
  # `default_net` is `NOT NULL` with the permissive default, and that default is
  # load-bearing beyond the usual reason: every space created from a blueprint
  # takes its `network_access` from here, and a blueprint that said nothing would
  # otherwise have to be special-cased as "no opinion" — which is not a thing a
  # blueprint should be able to be. The seed script sets Chat's to `false` (it was
  # the only seeded root whose mode had `net: false`); every other blueprint, and
  # every row this migration does not touch, keeps `true`, which is what a space
  # got before this column existed.
  #
  # `default_spawnable_vocation` is deliberately **nullable**, and `NULL` is a
  # real answer rather than a missing one: it means "this blueprint does not say
  # which vocation an unnamed spawn should get", and `agents-spawn` refuses an
  # omitted `vocation` rather than guessing (the caller's own vocation was the
  # guess, and it was wrong often enough to be the glitch this fixes). No
  # derivation is possible or wanted: there is no value that preserves the old
  # behaviour *and* is explicit, which is the whole point of the column.
  def up do
    alter table(:blueprints) do
      add :default_net, :boolean, null: false, default: true
      add :default_spawnable_vocation, :string
    end
  end

  def down do
    alter table(:blueprints) do
      remove :default_net
      remove :default_spawnable_vocation
    end
  end
end
