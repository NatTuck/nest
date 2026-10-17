defmodule Nest.Repo.Migrations.BackfillSpaceWorkspacePath do
  use Ecto.Migration

  # A space now requires a workspace: `Nest.Spaces.Space.create_changeset/2`
  # validates its presence, because the workspace is a space property its agents
  # inherit and the `act` mode — which every agent can be in — writes it.
  #
  # Rows written before that rule have none. They are given a deliberately *fake*
  # path rather than a plausible one. It is not a directory, so
  # `Nest.Sandbox.workspace_error/1` refuses it as `:workspace_missing`, which is
  # the loud failure we want: the space's commands fail with a reason a human can
  # see, and the edit dialog forces a real path before anything can run. Quietly
  # inventing a real-looking directory would hide the fact that somebody has to
  # choose one.
  @fake_workspace "/totally-fake-path-please-fix/"

  def up do
    execute(
      "UPDATE spaces SET workspace_path = '#{@fake_workspace}' WHERE workspace_path IS NULL"
    )
  end

  # The inverse, as far as there is one: rows that still hold the sentinel go back
  # to `NULL`. It cannot be exact — the sentinel is also a value a human could
  # have typed, and a row whose path has since been edited to something real is
  # indistinguishable from one that never had the sentinel. Restoring `NULL` for
  # the rows that still carry it is the honest best effort, and the column itself
  # is untouched.
  def down do
    execute("UPDATE spaces SET workspace_path = NULL WHERE workspace_path = '#{@fake_workspace}'")
  end
end
