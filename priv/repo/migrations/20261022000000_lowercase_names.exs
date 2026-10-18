defmodule Nest.Repo.Migrations.LowercaseNames do
  use Ecto.Migration

  import Ecto.Query

  # `Nest.Name` says a name is `[a-z0-9_-]+`, and both consumers read it from
  # there: `Nest.Agents.PersistedAgent.changeset/2` at the DB boundary and
  # `Nest.Accounts.User.registration_changeset/2` on the way in. `agents.name`
  # and `users.username` were both written under looser rules — agent names
  # allowed capitals, usernames allowed anything — so this migration brings
  # existing rows up to the one rule.
  #
  # Self-contained on purpose, like `20261011000000_sanitize_agent_names.exs`:
  # the rewrite rules are inlined rather than delegating to `Nest.Name`, so this
  # migration keeps doing exactly what it did when it ran, whatever that module
  # does later.
  #
  # ## Why it is not cosmetic for agents
  #
  # An agent's name is its scratch-directory segment (`Nest.Sandbox.Paths`:
  # `/tmp/<name>`), so a lowercased name is a **different directory**. Two
  # arms exist for that:
  #
  # * **A scratch directory that exists is a refusal, not a rename.** If
  #   `/tmp/<old>` is there, renaming the row would leave the old directory
  #   orphaned and point the agent at a fresh empty one. The migration raises,
  #   naming every offending agent, and the transaction rolls back — nothing is
  #   renamed. (On a `none` space that directory is the host's own `/tmp`, so a
  #   move would be moving host state; the refusal is the same either way.)
  # * **A space's root agent is a refusal too.** `Nest.Spaces.Creation` names
  #   the root agent `<slug>-root` and resolves it the same way, so lowercasing
  #   such an agent would leave the slug (a URL) disagreeing with the name
  #   derived from it. Lowercasing the slug as well is a URL change, which is
  #   the operator's call rather than a migration's, so this raises instead.
  #
  # ## Collisions
  #
  # Lowercasing is many-to-one: `Foo` and `foo` in one space fold to the same
  # candidate. Within a space, every already-safe name is reserved, rows are
  # processed in `id` order, and a taken candidate gains a
  # `-<6 hex of sha256(name + attempt)>` suffix (lengthening the digest only if
  # even that is taken), exactly as the sibling migration does it.
  # `(space_id, name)` stays unique throughout.
  #
  # `users.username` is `citext` with a case-insensitive unique index, so two
  # usernames that differ only in case cannot already coexist and lowercasing
  # one cannot collide with another. A fold that lands on a *different* name
  # (`"Jane Doe"` -> `jane-doe`) can still collide with an existing one, so the
  # same disambiguation applies; the reserved set is compared lowercased.
  #
  # ## The agent's own system message
  #
  # The index-0 system prompt embeds the name twice — `Your name is "<name>"`
  # and `Your own scratch directory is `/tmp/<name>/`` — so renaming the row
  # without it leaves the agent's own prompt (which the UI shows) contradicting
  # its name. Only those two exact renderings are replaced, and only in the
  # agent's own index-0 `system` row.
  #
  # ## Reversibility
  #
  # The mapping is recorded in `lowercase_name_migrations` (created here), which
  # is what `down/0` restores from: the original capitalisation is not
  # reconstructible from the lowercased form. It covers both subjects — `agents`
  # and `users` — because both were rewritten. The system-message rewrite is
  # exactly invertible, so `down/0` reverses it in place rather than storing a
  # copy of the old prompt.
  #
  # ## Ordering
  #
  # This runs in `Ecto.Migrator`'s child spec, which `Nest.Application` starts
  # *before* `Nest.Agents.Supervisor`, so no agent process exists while the
  # rewrite happens. Applying it with `mix ecto.migrate` against a *running*
  # server is not safe — a live agent keeps its old name in memory and resolves
  # its own row by name on every write — and this migration cannot detect
  # liveness from the database, so that stays an operational rule: stop the
  # server, or migrate at boot.

  @max_name_bytes 255
  @digest_length 6
  @fallback_agent "agent"
  @fallback_user "user"
  @sandbox_root "/tmp"

  # Runs of characters that are not allowed in a name. Matched with the `u` flag
  # so a multi-byte character is one run, not one per byte. `_` and `-` are
  # allowed, so a name that is already valid is never touched.
  @unsafe_run ~r/[^a-z0-9_-]+/u

  # Combining marks left by NFD decomposition, stripped so accented Latin
  # letters fold to their base letter instead of being dropped.
  @combining_marks ~r/[\x{0300}-\x{036F}]+/u

  # The rule a name has to satisfy afterwards.
  @name_format ~r/\A[a-z0-9_-]+\z/

  def up do
    create table(:lowercase_name_migrations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :subject, :string, null: false
      add :row_id, :bigint, null: false
      add :space_id, :bigint
      add :old_name, :string, null: false
      add :new_name, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    flush()

    lowercase_agent_names()
    lowercase_usernames()
  end

  def down do
    flush()

    restore_names()

    drop table(:lowercase_name_migrations)
  end

  @doc false
  # Rewrite every agent name that is not already `[a-z0-9_-]+`, in place, and
  # record each mapping.
  #
  # Public, and reaching the database through `Nest.Repo` rather than the
  # migrator's `repo()` — `repo()` needs a live migration-runner process, which
  # would make this callable only from inside a migration. Keeping it callable
  # is what lets the test suite drive the rewrite against rows it inserted.
  def lowercase_agent_names do
    rows = agents()

    refuse_occupied_scratch_dirs(rows)
    refuse_root_agents(rows)

    rows
    |> Enum.group_by(fn {_id, space_id, _name} -> space_id end)
    |> Enum.each(fn {space_id, rows} -> lowercase_space(space_id, rows) end)
  end

  @doc false
  # Rewrite every username that is not already `[a-z0-9_-]+`, in place, and
  # record each mapping.
  def lowercase_usernames do
    rows = users()
    taken = rows |> Enum.map(fn {_id, name} -> String.downcase(name) end) |> MapSet.new()

    Enum.reduce(rows, taken, fn {id, old_name}, taken ->
      if safe?(old_name) do
        taken
      else
        new_name = folded_name(old_name, @fallback_user, taken)
        rename_user(id, new_name)
        record("users", id, nil, old_name, new_name)
        MapSet.put(taken, new_name)
      end
    end)

    :ok
  end

  @doc false
  # Put the original names back. It runs inside the migration's transaction, so
  # a failure (a row hand-inserted with a name that now collides, say) rolls the
  # whole migration back rather than leaving names half-restored.
  #
  # Order does not matter for collisions: every name this migration wrote is
  # lowercase and every name it restores is not, so no restore can collide with
  # a name that is still in place.
  def restore_names do
    for {subject, row_id, old_name, new_name} <- recorded_renames() do
      case subject do
        "agents" ->
          rewrite_system_message(row_id, new_name, old_name)
          rename_agent(row_id, old_name)

        "users" ->
          rename_user(row_id, old_name)
      end
    end
  end

  # --- refusals ---

  # A scratch directory that exists belongs to the old name. Renaming the row
  # would orphan it and point the agent at a fresh empty one, so this refuses —
  # reporting every offender at once — rather than moving or deleting anything.
  defp refuse_occupied_scratch_dirs(rows) do
    offenders =
      for {id, space_id, name} <- rows,
          not safe?(name),
          File.exists?(scratch_dir(name)),
          do: {id, space_id, name, scratch_dir(name)}

    if offenders != [] do
      raise """
      refusing to lowercase agent names: the scratch directory of a name this
      migration would change already exists on disk, so renaming the row would
      orphan it (and point the agent at a fresh, empty one):

      #{Enum.map_join(offenders, "\n", &offender_line/1)}

      Move or remove each directory first — or rename that agent by hand — and
      run the migration again.
      """
    end
  end

  # A space's root agent is named `<slug>-root` by `Nest.Spaces.Creation` and
  # resolved the same way, so changing the agent's name without changing the
  # slug would leave the two disagreeing. Lowercasing the slug is a URL change,
  # which is the operator's decision, not a migration's.
  defp refuse_root_agents(rows) do
    slugs = Map.new(spaces(), fn {space_id, slug} -> {space_id, slug} end)

    offenders =
      for {id, space_id, name} <- rows,
          not safe?(name),
          slug = Map.get(slugs, space_id),
          is_binary(slug),
          name == slug <> "-root",
          do: {id, space_id, name, slug}

    if offenders != [] do
      raise """
      refusing to lowercase agent names: these are their spaces' root agents, so
      the name is derived from the space's slug — and the slug is not lowercase,
      so the two would disagree after the rename:

      #{Enum.map_join(offenders, "\n", &root_offender_line/1)}

      Lowercase the space's slug (a URL change) first, or rename the agent by
      hand, and run the migration again.
      """
    end
  end

  defp offender_line({id, space_id, name, dir}) do
    "  agent #{id} (space #{space_id}) #{inspect(name)} -> #{dir}"
  end

  defp root_offender_line({id, space_id, name, slug}) do
    "  agent #{id} (space #{space_id}) #{inspect(name)} is the root of slug #{inspect(slug)}"
  end

  # --- the rewrite ---

  # A space's rows in `id` order: already-safe names are reserved first, so a
  # folded candidate can never steal one of them.
  defp lowercase_space(space_id, rows) do
    rows
    |> Enum.sort_by(fn {id, _space_id, _name} -> id end)
    |> Enum.reduce(reserved_names(space_id), fn {id, _space_id, old_name}, taken ->
      if safe?(old_name) do
        taken
      else
        new_name = folded_name(old_name, @fallback_agent, taken)
        rename_agent(id, new_name)
        rewrite_system_message(id, old_name, new_name)
        record("agents", id, space_id, old_name, new_name)

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

  defp users do
    Nest.Repo.all(from(u in "users", order_by: [asc: u.id], select: {u.id, u.username}))
  end

  defp spaces do
    Nest.Repo.all(from(s in "spaces", order_by: [asc: s.id], select: {s.id, s.slug}))
  end

  defp recorded_renames do
    Nest.Repo.all(
      from(m in "lowercase_name_migrations",
        order_by: [asc: m.id],
        select: {m.subject, m.row_id, m.old_name, m.new_name}
      )
    )
  end

  defp safe?(name) do
    is_binary(name) and byte_size(name) <= @max_name_bytes and Regex.match?(@name_format, name)
  end

  # The readable fold of `old_name`, disambiguated against `taken` when needed.
  #
  # Length is already bounded: `agents.name` is `varchar(255)` and this fold
  # never grows a name — the multi-character decompositions NFD applies are a
  # base letter plus combining marks (stripped), and Hangul syllables into jamo,
  # which are not `[a-z0-9]` and so collapse into the single `-` that
  # `@unsafe_run` produces. Do not "improve" this into NFKD (which applies the
  # compatibility mappings, so `ﬁ` becomes `fi` and a 255-character name can
  # fold to 510 characters) or add a prefix. The `-<digest>` suffix is the one
  # thing that can push past the cap, which is why `disambiguated/4` truncates
  # the base before appending.
  defp folded_name(old_name, fallback, taken) do
    base = base_name(old_name, fallback)

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

  defp base_name(old_name, fallback) do
    base =
      old_name
      |> nfd_fold()
      |> String.downcase()
      |> String.replace(@unsafe_run, "-")
      |> trim()

    if base == "", do: fallback, else: base
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

  # --- the system message ---

  # Rewrite the two prompt renderings that embed the agent's name, in the
  # agent's own index-0 `system` row. A general search-and-replace of the old
  # name would also rewrite prose that merely mentions it — an AGENTS.md
  # excerpt, a sibling's name in a transcript — which is why the needles are the
  # composer's own sentences (`Nest.Agents.Agent.SystemPrompt`).
  #
  # The walk runs on the *decoded* jsonb map and the write goes back through
  # Ecto, so JSON escaping is the driver's problem rather than a
  # string-matching problem here. Rows whose text does not change are not
  # written at all.
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

  # Mirrors `Nest.Sandbox.Paths.scratch_dir/1`; inlined with the rest of this
  # migration's rules so the file stays self-contained.
  defp scratch_dir(name), do: @sandbox_root <> "/" <> name

  defp update_message_content(message_id, content) do
    Nest.Repo.update_all(from(m in "messages", where: m.id == ^message_id),
      set: [content: content]
    )
  end

  defp rename_agent(agent_id, name) do
    Nest.Repo.update_all(from(a in "agents", where: a.id == ^agent_id), set: [name: name])
  end

  defp rename_user(user_id, username) do
    Nest.Repo.update_all(from(u in "users", where: u.id == ^user_id), set: [username: username])
  end

  defp record(subject, row_id, space_id, old_name, new_name) do
    Nest.Repo.insert_all("lowercase_name_migrations", [
      %{
        subject: subject,
        row_id: row_id,
        space_id: space_id,
        old_name: old_name,
        new_name: new_name,
        inserted_at: DateTime.utc_now()
      }
    ])
  end
end
