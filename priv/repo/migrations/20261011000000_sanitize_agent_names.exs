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
  # * **The agent's own system message is rewritten too.** The index-0
  #   system prompt embeds the name twice (`Your name is "<name>"` and
  #   `Your own scratch directory is `/tmp/<name>/``), so renaming the row
  #   without it leaves the agent's own prompt — which the UI shows —
  #   contradicting its name. Only those two exact renderings are replaced,
  #   only in the agent's own index-0 system row. See
  #   `rewrite_system_message/3`.
  # * **Reversibility.** The mapping is recorded in
  #   `agent_name_migrations` (created here), which is what `down/0`
  #   restores from — an unsafe name is not reconstructible from its safe
  #   form, so without the record the rewrite would be irreversible. It is
  #   also the only record of "this agent used to be called X", which is
  #   what a future scratch-dir rename would need. The system-message
  #   rewrite is exactly invertible, so `down/0` reverses it in place
  #   rather than storing a copy of the old prompt (see
  #   `restore_names/0`).
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
  @sandbox_root "/tmp"

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
  #
  # The system message is restored by applying the same two-rendering
  # rewrite backwards, not by storing a copy of the old prompt: an index-0
  # system row is written once at create and never rewritten by the
  # application, so the text the inverse rewrite produces is exactly the
  # text this migration found. (For a row migrated before the scratch line
  # existed, the inverse of the scratch rendering simply matches nothing.)
  def restore_names do
    for {agent_id, _space_id, old_name, new_name} <- recorded_renames() do
      rewrite_system_message(agent_id, new_name, old_name)
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
        rewrite_system_message(id, old_name, new_name)

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
        select: {m.agent_id, m.space_id, m.old_name, m.new_name}
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

  # Rewrite the two prompt renderings that embed the agent's name in its
  # own index-0 system message: the identity sentence and the scratch-dir
  # line, both composed by `Nest.Agents.Agent.SystemPrompt`.
  #
  # Only those two exact renderings are replaced, and only in this agent's
  # own index-0 `system` row. A general search-and-replace of the old name
  # would also rewrite prose that merely mentions it — an AGENTS.md excerpt,
  # a sibling's name in a transcript, the agent's own name inside another
  # sentence — which is why the needles are the composer's sentences.
  #
  # The walk runs on the *decoded* jsonb map and the write goes back through
  # Ecto, so JSON escaping (a `"` in a name, a non-ASCII byte) is the
  # driver's problem rather than a string-matching problem here. Rows whose
  # text does not change are not written at all.
  defp rewrite_system_message(agent_id, old_name, new_name) do
    rows =
      Nest.Repo.all(
        from(m in "messages",
          where: m.agent_id == ^agent_id and m.message_index == 0 and m.role == "system",
          select: {m.id, m.content}
        )
      )

    Enum.each(rows, fn {message_id, content} ->
      case rewrite_content(content, old_name, new_name) do
        nil -> :ok
        new_content -> update_message_content(message_id, new_content)
      end
    end)

    :ok
  end

  defp rewrite_content(%{"parts" => parts} = content, old_name, new_name) when is_list(parts) do
    rewritten = Enum.map(parts, &rewrite_part(&1, old_name, new_name))

    if rewritten == parts, do: nil, else: Map.put(content, "parts", rewritten)
  end

  defp rewrite_content(_content, _old_name, _new_name), do: nil

  defp rewrite_part(%{"kind" => "text", "text" => text} = part, old_name, new_name)
       when is_binary(text) do
    Map.put(part, "text", rewrite_text(text, old_name, new_name))
  end

  defp rewrite_part(part, _old_name, _new_name), do: part

  defp rewrite_text(text, old_name, new_name) do
    text
    |> String.replace(name_rendering(old_name), name_rendering(new_name))
    |> String.replace(scratch_rendering(old_name), scratch_rendering(new_name))
  end

  defp name_rendering(name), do: ~s(Your name is "#{name}")

  defp scratch_rendering(name), do: "Your own scratch directory is `#{scratch_dir(name)}/`"

  # Mirrors `Nest.Sandbox.Paths.sandbox_root/0`; inlined with the rest of
  # this migration's rules so the file stays self-contained.
  defp scratch_dir(name), do: @sandbox_root <> "/" <> name

  defp update_message_content(message_id, content) do
    Nest.Repo.update_all(from(m in "messages", where: m.id == ^message_id),
      set: [content: content]
    )
  end

  defp rename_agent(agent_id, name) do
    Nest.Repo.update_all(from(a in "agents", where: a.id == ^agent_id), set: [name: name])
  end

  defp record(row) do
    Nest.Repo.insert_all("agent_name_migrations", [Map.put(row, :inserted_at, DateTime.utc_now())])
  end
end
