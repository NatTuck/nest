defmodule Nest.Repo.Migrations.DropModesFromVocations do
  use Ecto.Migration

  # The modes are universal code constants (`Nest.Modes`) from here on: there are
  # exactly two, `plan` and `act`, they are the same for every vocation, and a
  # mode is a *per-agent* runtime property (`agents.mode`) rather than something
  # a vocation declares. Nothing has read this column since the modes became
  # constants — `Nest.Vocations.get_caps/2` and its siblings answered from
  # `Nest.Modes` while it was still here — so dropping it removes dead data
  # rather than a capability.
  #
  # No data is preserved and none needs to be: every row's `modes` described the
  # same two modes, and the caps those modes resolve to now live in
  # `Nest.Modes.caps/1`.
  def up do
    alter table(:vocations) do
      remove :modes
    end
  end

  def down do
    alter table(:vocations) do
      add :modes, :map
    end
  end
end
