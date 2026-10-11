defmodule Nest.Repo.Migrations.SanitizeAgentNames do
  use Ecto.Migration

  import Ecto.Query

  # An agent's name doubles as its scratch-directory segment
  # (`Nest.Agents.Agent.TmpSpace.agent_dir/2`), so it must be a single
  # filename-safe component. `PersistedAgent.changeset/2` enforces
  # `[A-Za-z0-9_-]+` with a 255-byte cap on every insert from now on; this
  # migration brings existing rows up to that rule, because a name that
  # violates it would either fail at start-up (a 258-byte directory
  # component: `File.Error :enametoolong`) or, for `..`, make
  # `TmpSpace.cleanup/2` delete the whole shared `nest-<ospid>` scratch
  # root.
  #
  # Self-contained on purpose, like the other data migrations here: the
  # rewrite rules are inlined rather than delegating to `Nest.Slug` or the
  # schema, so this migration keeps doing exactly what it did when it ran,
  # whatever those modules do later.
  #
  # ## Design notes
  #
  # * **The rewrite is user-visible.** `agents.name` is the name shown in
  #   the lobby and used to address the agent (`agents-send`, the
  #   `{space_id, name}` ownership key, `agents-list`). A rename is
  #   therefore a real change, not a path detail. The rewrite keeps the
  #   original as recognizable as it can: NFD-fold accented letters
  #   ("Café" -> "cafe"), lowercase, replace every run of other
  #   characters with `-`, and trim leading/trailing dashes. A name with
  #   nothing left (e.g. all-CJK, which has no ASCII fold) becomes
  #   `agent`. Only names that are *not already safe* are touched, so
  #   every slug-like name is left exactly as it is.
  # * **Collisions.** Two unsafe names can fold to the same candidate, and
  #   a candidate can collide with a name another row already holds
  #   (`"Foo Bar"` -> `foo-bar` while `foo-bar` exists). Within a space,
  #   every already-safe name is reserved, rows are processed in `id`
  #   order, and a candidate that is taken gains a `-<6 hex of
  #   sha256(name + attempt)>` suffix (lengthening the digest only if even
  #   that is taken). `(space_id, name)` stays unique throughout.
  # * **Reversibility.** The mapping is recorded in
  #   `agent_name_migrations` (created here), which is what `down/0`
  #   restores from — an unsafe name is not reconstructible from its safe
  #   form, so without the record the rewrite would be irreversible. It is
  #   also the only record of "this agent used to be called X", which is
  #   what a future scratch-dir rename would need.
  # * **Scratch directories on disk are not touched.** A scratch dir is
  #   `/tmp/nest-<BEAM os pid>/space-<space_id>/<name>`, and that OS pid
  #   belongs to the BEAM that created it — a migration running in some
  #   other (or a restarted) BEAM cannot even compute the path, and any
  #   path it could compute is already stale. The agent's next start
  #   creates `<new name>/` on demand; the old directory, if any, stays
  #   where it is and is left to OS `/tmp` cleanup, exactly like every
  #   other scratch dir from a previous BEAM.
  # * **Ordering.** This runs in `Ecto.Migrator`'s child spec, which
  #   `Nest.Application` starts *before* `Nest.Agents.Supervisor`
  #   (lib/nest/application.ex), so no agent process exists while the
  #   rewrite happens and no agent can be desynchronized from its row.
  #   Applying it with `mix ecto.migrate` against a *running* server is
  #   not safe — a live agent keeps its old name in memory and resolves
  #   its own row by name on every write — but this migration cannot
  #   detect liveness from the database alone, so that is an operational
  #   rule: stop the server (or migrate at boot).

  @max_name_bytes 255
  @digest_length 6
  @fallback_name "agent"

  # Runs of characters that are not allowed in a name. Matched with the
  # `u` flag so a multi-byte character is one run, not one per byte.
  @unsafe_run ~r/[^a-z0-9]+/u

  # Combining marks left by NFD decomposition, stripped so accented Latin
  # letters fold to their base letter instead of being dropped.
  @combining_marks ~r/[\x{0300}-\x{036F}]+/u

  def up do
    create table(:agent_name_migrations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :agent_id, :bigint, null: false
      add :space_id, :bigint, null: false
      add :old_name, :string, null: false
      add :new_name, :string, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    flush()

    sanitize_names()
  end

  def down do
    flush()

    restore_names()

    drop table(:agent_name_migrations)
  end

  @doc false
  # Rewrite every unsafe `agents.name` in place and record each mapping.
  #
  # Public, and reaching the database through `Nest.Repo` rather than the
  # migrator's `repo()` — `repo()` needs a live migration-runner process,
  # which would make this callable only from inside a migration. Keeping it
  # callable is what lets the test suite drive the rewrite against rows it
  # inserted. `up/0` calls it right after the audit table exists.
  def sanitize_names do
    agents()
    |> Enum.group_by(fn {_id, space_id, _name} -> space_id end)
    |> Enum.each(fn {space_id, rows} -> sanitize_space(space_id, rows) end)
  end

  @doc false
  # Put the original names back. The originals are unsafe by definition and
  # `PersistedAgent.changeset/2` refuses unsafe names, so a row created
  # after the migration cannot be holding one: the restore cannot collide.
  # It runs inside the migration's transaction, so a failure (a row
  # hand-inserted with a raw name, say) rolls the whole migration back
  # rather than leaving names half-restored.
  def restore_names do
    for {agent_id, _space_id, old_name} <- recorded_renames() do
      rename_agent(agent_id, old_name)
    end
  end

  # A space's rows in `id` order: already-safe names are reserved first, so
  # a folded candidate can never steal one of them.
  defp sanitize_space(space_id, rows) do
    rows
    |> Enum.sort_by(fn {id, _space_id, _name} -> id end)
    |> Enum.reduce(reserved_names(space_id), fn {id, _space_id, old_name}, taken ->
      if safe?(old_name) do
        taken
      else
        new_name = folded_name(old_name, taken)
        rename_agent(id, new_name)

        record(%{
          agent_id: id,
          space_id: space_id,
          old_name: old_name,
          new_name: new_name
        })

        MapSet.put(taken, new_name)
      end
    end)
  end

  defp reserved_names(space_id) do
    Nest.Repo.all(from(a in "agents", where: a.space_id == ^space_id, select: a.name))
    |> Enum.filter(&safe?/1)
    |> MapSet.new()
  end

  defp agents do
    Nest.Repo.all(
      from(a in "agents",
        order_by: [asc: a.space_id, asc: a.id],
        select: {a.id, a.space_id, a.name}
      )
    )
  end

  defp recorded_renames do
    Nest.Repo.all(
      from(m in "agent_name_migrations",
        order_by: [asc: m.id],
        select: {m.agent_id, m.space_id, m.old_name}
      )
    )
  end

  defp safe?(name) do
    is_binary(name) and byte_size(name) <= @max_name_bytes and name =~ ~r/\A[A-Za-z0-9_-]+\z/
  end

  # The readable fold of `old_name`, disambiguated against `taken` when
  # needed.
  #
  # Length is already bounded: `agents.name` is `varchar(255)`, and this
  # fold never grows a name (a run of any length collapses to one `-`, NFD
  # only removes marks, and the result is ASCII, so characters == bytes).
  # The `-<digest>` suffix is the one thing that can push it over, which is
  # why `disambiguated/4` truncates before appending.
  defp folded_name(old_name, taken) do
    base = base_name(old_name)

    if MapSet.member?(taken, base) do
      disambiguated(base, old_name, taken, 1)
    else
      base
    end
  end

  defp disambiguated(base, old_name, taken, attempt) do
    suffix = "-" <> digest(old_name, attempt)
    candidate = trim(String.slice(base, 0, @max_name_bytes - byte_size(suffix))) <> suffix

    if MapSet.member?(taken, candidate) do
      disambiguated(base, old_name, taken, attempt + 1)
    else
      candidate
    end
  end

  defp base_name(old_name) do
    base =
      old_name
      |> nfd_fold()
      |> String.downcase()
      |> String.replace(@unsafe_run, "-")
      |> trim()

    if base == "", do: @fallback_name, else: base
  end

  defp nfd_fold(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(@combining_marks, "")
  end

  defp trim(name), do: String.trim(name, "-")

  defp digest(old_name, attempt) do
    :crypto.hash(:sha256, old_name <> Integer.to_string(attempt))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @digest_length)
  end

  defp rename_agent(agent_id, name) do
    Nest.Repo.update_all(from(a in "agents", where: a.id == ^agent_id), set: [name: name])
  end

  defp record(row) do
    Nest.Repo.insert_all("agent_name_migrations", [Map.put(row, :inserted_at, DateTime.utc_now())])
  end
end
