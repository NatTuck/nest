defmodule Nest.LowercaseNamesMigrationTest do
  @moduledoc """
  Tests for the `lowercase_names` data migration, which brings existing
  `agents.name` and `users.username` rows up to the `[a-z0-9_-]+` / 255-byte
  rule `Nest.Name` states and both schemas enforce.

  The migration file lives in `priv/repo/migrations/` (a `.exs` script, not
  compiled into the app), so this suite `Code.require_file/1`s it and drives
  its data functions directly against rows it inserted. The DDL half of `up/0`
  already ran: `mix test` migrates the test database before the suite starts.
  `down/0` cannot run here for the same reason, so its data half —
  `restore_names/0` — is what the `down` describe drives.

  `async: true` — every test inserts its own rows into its own space and the
  SQL sandbox rolls the rewrites back. The scratch-directory refusals read the
  real `/tmp`, so their names are unique and their directories are removed on
  exit.
  """
  use Nest.DataCase, async: true

  import Ecto.Query

  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.Paths

  @migration_file "priv/repo/migrations/20261022000000_lowercase_names.exs"

  # Every scratch-directory test names its directory with this tag, so the
  # cleanup can be guarded by it (SMELLS.md: an `rm_rf` of a temp directory is
  # guarded by an identifying string in the path).
  @scratch_tag "nest-migration-test"

  # The migration is a `.exs` script under `priv/`, so it is not compiled
  # with the app: it is loaded at runtime — by `mix ecto.migrate` before the
  # suite runs, or by the `Code.require_file/1` in `setup_all` below. Silence
  # the compile-time "module is not available" warning for the calls to it.
  @compile {:no_warn_undefined, Nest.Repo.Migrations.LowercaseNames}

  setup_all do
    # `mix test` (via the `test` alias in mix.exs) migrates the test
    # database first, which already loads this module into the BEAM. Only
    # require the file when that has not happened.
    unless Code.ensure_loaded?(Nest.Repo.Migrations.LowercaseNames) do
      Code.require_file(@migration_file)
    end

    :ok
  end

  # The migration module, defined by the `Code.require_file/1` above.
  defp migration, do: Nest.Repo.Migrations.LowercaseNames

  defp lowercase_agent_names, do: migration().lowercase_agent_names()
  defp lowercase_usernames, do: migration().lowercase_usernames()
  defp restore_names, do: migration().restore_names()

  describe "up (rewriting agent names)" do
    test "rewrites unsafe names to readable, safe equivalents" do
      space_id = space()
      plain = insert_agent(space_id, "My Agent")
      accented = insert_agent(space_id, "Café ☕")
      cjk = insert_agent(space_id, "漢字")

      lowercase_agent_names()

      # Accents fold to their base letter; a name with no ASCII fold at all falls
      # back to `agent` rather than being stored empty.
      assert name(space_id, plain) == "my-agent"
      assert name(space_id, accented) == "cafe"
      assert name(space_id, cjk) == "agent"

      assert recorded_agents(space_id) == [
               {"My Agent", "my-agent"},
               {"Café ☕", "cafe"},
               {"漢字", "agent"}
             ]
    end

    test "leaves an already-safe name untouched and records nothing" do
      space_id = space()
      id = insert_agent(space_id, "already-safe_1")

      lowercase_agent_names()

      assert name(space_id, id) == "already-safe_1"
      assert recorded_agents(space_id) == []
    end

    test "disambiguates two unsafe names that fold to the same candidate" do
      space_id = space()
      first = insert_agent(space_id, "Foo Bar")
      second = insert_agent(space_id, "foo-bar!")

      lowercase_agent_names()

      # `id` order decides who keeps the clean fold.
      assert name(space_id, first) == "foo-bar"
      assert name(space_id, second) =~ ~r/\Afoo-bar-[0-9a-f]{6}\z/
    end

    test "never steals a name another row already holds" do
      space_id = space()
      keeper = insert_agent(space_id, "foo-bar")
      folded = insert_agent(space_id, "Foo Bar")

      lowercase_agent_names()

      assert name(space_id, keeper) == "foo-bar"
      assert name(space_id, folded) =~ ~r/\Afoo-bar-[0-9a-f]{6}\z/
    end

    test "scopes uniqueness to a space: the same unsafe name folds cleanly in both" do
      mine = space()
      theirs = space()
      mine_id = insert_agent(mine, "Shared Name")
      theirs_id = insert_agent(theirs, "Shared Name")

      lowercase_agent_names()

      # No digest suffix: `(space_id, name)` is the unique key, so the two
      # rows never see each other.
      assert name(mine, mine_id) == "shared-name"
      assert name(theirs, theirs_id) == "shared-name"
    end

    test "is idempotent" do
      space_id = space()
      id = insert_agent(space_id, "Idempotent Agent")

      lowercase_agent_names()
      after_first = name(space_id, id)
      recorded_after_first = recorded_agents(space_id)

      lowercase_agent_names()

      assert name(space_id, id) == after_first
      assert recorded_agents(space_id) == recorded_after_first
    end
  end

  describe "up (the agent's own system message)" do
    test "is rewritten to the new name and scratch dir" do
      space_id = space()
      id = insert_agent(space_id, "Foo Bar")
      insert_system_message(id, "Foo Bar")

      lowercase_agent_names()

      assert name(space_id, id) == "foo-bar"

      text = system_text(id)
      assert text =~ ~s(Your name is "foo-bar")
      assert text =~ "Your own scratch directory is `/tmp/foo-bar/`"
      refute text =~ "Foo Bar"
      refute text =~ "/tmp/Foo Bar/"
    end

    test "leaves text that is not one of the two renderings alone" do
      space_id = space()
      id = insert_agent(space_id, "Foo Bar")

      insert_system_message(id, "Foo Bar",
        extra: "\n\nAn AGENTS.md excerpt mentions the agent Foo Bar by name."
      )

      lowercase_agent_names()

      text = system_text(id)
      assert text =~ ~s(Your name is "foo-bar")

      # Prose is not a rendering the composer emits, so it is untouched: a
      # general search-and-replace of the old name would have rewritten it.
      assert text =~ "mentions the agent Foo Bar by name"
    end

    test "only the index-0 system row is touched" do
      space_id = space()
      id = insert_agent(space_id, "Foo Bar")
      insert_system_message(id, "Foo Bar")
      # A later row that happens to carry the same sentence is a transcript,
      # not the prompt: leave it alone.
      insert_message(id, 1, "user", ~s(They said: Your name is "Foo Bar"))

      lowercase_agent_names()

      assert system_text(id) =~ ~s(Your name is "foo-bar")
      assert text_at(id, 1) =~ ~s(Your name is "Foo Bar")
    end

    test "is a no-op for an agent with no system row (a clone owns none)" do
      space_id = space()
      id = insert_agent(space_id, "Clone Name")

      lowercase_agent_names()

      assert name(space_id, id) == "clone-name"
      assert Nest.Repo.all(from(m in "messages", where: m.agent_id == ^id, select: m.id)) == []
    end
  end

  describe "up (rewriting usernames)" do
    test "rewrites unsafe usernames to the shared fold" do
      jane = insert_user("Jane Doe")
      at_nat = insert_user("@Nat")
      cjk = insert_user("漢字")

      lowercase_usernames()

      # `@Nat` loses the `@` and the capital; a name with no ASCII fold at all
      # falls back to `user` rather than being stored empty.
      assert username(jane) == "jane-doe"
      assert username(at_nat) == "nat"
      assert username(cjk) == "user"

      assert recorded_users() == [
               {"Jane Doe", "jane-doe"},
               {"@Nat", "nat"},
               {"漢字", "user"}
             ]
    end

    test "leaves an already-safe username untouched and records nothing" do
      id = insert_user("already_safe-1")

      lowercase_usernames()

      assert username(id) == "already_safe-1"
      assert recorded_users() == []
    end

    test "disambiguates a fold that collides with an existing username" do
      keeper = insert_user("jane-doe")
      folded = insert_user("Jane Doe")

      lowercase_usernames()

      assert username(keeper) == "jane-doe"
      assert username(folded) =~ ~r/\Ajane-doe-[0-9a-f]{6}\z/
    end

    test "keeps a long username within the byte cap the changeset accepts" do
      # The old changeset cap was 64 characters; the shared rule is 255 bytes. A
      # 255-character username folds to at most 255 bytes, so the migrated name
      # is one `registration_changeset/2` would accept.
      id = insert_user(String.duplicate("A", Nest.Name.max_bytes()))

      lowercase_usernames()

      assert byte_size(username(id)) == Nest.Name.max_bytes()
      assert Nest.Name.valid?(username(id))
    end
  end

  describe "the scratch directory a rename would orphan" do
    test "refuses a marked none-space scratch directory" do
      space_id = space("none")
      name = scratch_name()
      id = insert_agent(space_id, name)
      # The directory of the name the rename would leave, which is the old name.
      dir = marked_scratch(name)

      message = assert_raise RuntimeError, fn -> lowercase_agent_names() end

      # The message says what was actually detected, that it aborts the whole
      # migration (the username rewrite included), and names the directory.
      assert message.message =~ "`.nest-scratch` marker"
      assert message.message =~ dir
      assert message.message =~ "username rewrite"
      assert name(space_id, id) == name
    end

    test "leaves a host directory without Nest's marker alone" do
      space_id = space("none")
      name = scratch_name()
      id = insert_agent(space_id, name)
      folded = Nest.Name.sanitize(name)
      # The path the migration checks is the *old* name's; this host directory
      # shares it but carries no marker, so it is not Nest's to refuse on.
      dir = host_dir(name)

      lowercase_agent_names()

      assert name(space_id, id) == folded
      assert File.dir?(dir)
    end

    test "checks no scratch directory on a bwrap space" do
      space_id = space()
      name = scratch_name()
      id = insert_agent(space_id, name)
      # A bwrap scratch is `/tmp/nest/<BEAM pid>/space-<id>/<name>`, which the
      # migration cannot compute (the pid belongs to the creating BEAM). Even a
      # marked directory at the `none` spelling is not this agent's scratch.
      marked_scratch(name)

      lowercase_agent_names()

      assert name(space_id, id) == Nest.Name.sanitize(name)
    end

    test "refuses a root agent whose space slug is not lowercase" do
      space_id = space()
      # The creation changeset refuses a capitalised slug, so this is a row a
      # previous build could have left behind.
      Nest.Repo.update_all(from(s in "spaces", where: s.id == ^space_id),
        set: [slug: "MySpace"]
      )

      id = insert_agent(space_id, "MySpace-root")

      message = assert_raise RuntimeError, fn -> lowercase_agent_names() end

      assert message.message =~ "root agents"
      assert message.message =~ "MySpace-root"
      assert name(space_id, id) == "MySpace-root"
    end
  end

  describe "down (restoring the original names)" do
    test "restores a recorded agent name and its system message" do
      space_id = space()
      id = insert_agent(space_id, "Restore Me")
      insert_system_message(id, "Restore Me")
      original = system_text(id)

      lowercase_agent_names()
      assert name(space_id, id) == "restore-me"
      refute system_text(id) == original

      restore_names()

      assert name(space_id, id) == "Restore Me"
      assert system_text(id) == original
      assert system_text(id) =~ ~s(Your name is "Restore Me")
    end

    test "restores a recorded username" do
      id = insert_user("Jane Doe")

      lowercase_usernames()
      assert username(id) == "jane-doe"

      restore_names()

      assert username(id) == "Jane Doe"
    end

    test "is a no-op for rows the migration never touched" do
      space_id = space()
      agent = insert_agent(space_id, "untouched_1")
      user = insert_user("untouched-1")

      lowercase_agent_names()
      lowercase_usernames()
      restore_names()

      assert name(space_id, agent) == "untouched_1"
      assert username(user) == "untouched-1"
    end

    test "refuses to restore a name whose marked none scratch it would orphan" do
      space_id = space("none")
      name = scratch_name()
      id = insert_agent(space_id, name)
      folded = Nest.Name.sanitize(name)

      lowercase_agent_names()
      assert name(space_id, id) == folded

      # The lowercase name is the one the rollback would rename away from, so
      # its directory is the one the rollback would orphan.
      dir = marked_scratch(folded)

      message = assert_raise RuntimeError, fn -> restore_names() end

      assert message.message =~ "restore agent names"
      assert message.message =~ dir
      assert name(space_id, id) == folded
    end
  end

  defp unique, do: System.unique_integer([:positive])

  defp space(backend \\ "bwrap") do
    {:ok, space} =
      Nest.Spaces.create_space(nil, %{
        workspace_path: AgentTestHelpers.default_test_workspace(),
        name: "lowercase-names-#{unique()}",
        slug: "lowercase-names-#{unique()}",
        sandbox_backend: backend
      })

    space.id
  end

  # Insert an agent row with an arbitrary (possibly unsafe) name. The
  # changeset now refuses those names, so the row goes in through
  # `insert_all`, which is also how the rows this migration exists for got
  # there.
  defp insert_agent(space_id, name) do
    now = DateTime.utc_now()

    {1, [%{id: id}]} =
      Nest.Repo.insert_all(
        "agents",
        [
          %{
            name: name,
            space_id: space_id,
            vocation_id: vocation_id(),
            model: %{name: "test-model", provider: "test"},
            next_message_index: 0,
            last_compaction_index: -1,
            depth: 0,
            shared: false,
            archived: false,
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    id
  end

  # A user row under the old, loose rule: the changeset sanitises now, so the
  # unsafe name goes in raw.
  defp insert_user(username) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, [%{id: id}]} =
      Nest.Repo.insert_all(
        "users",
        [
          %{
            username: username,
            password_hash: "not-a-real-hash",
            is_admin: false,
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    id
  end

  defp vocation do
    {:ok, vocation} =
      Nest.Vocations.upsert_vocation(%{
        name: "Lowercase Names Test",
        description: "Default for the lowercase-names migration test",
        system_prompt: "You are a helpful test assistant.",
        tools: ["context"]
      })

    vocation
  end

  defp vocation_id, do: vocation().id

  # The agent's own index-0 system message, composed the way the application
  # composes it (`Nest.Agents.Agent.SystemPrompt`), so this suite fails if
  # the composer's wording ever drifts away from the two renderings the
  # migration rewrites. `opts[:extra]` appends text that is NOT one of those
  # renderings.
  defp insert_system_message(agent_id, name, opts \\ []) do
    {prompt, _tools, _vocation} =
      SystemPrompt.compose_vocation_config(
        vocation(),
        Mounts.new(nil, nil),
        {nil, nil},
        name,
        0
      )

    insert_message(agent_id, 0, "system", prompt <> Keyword.get(opts, :extra, ""))
  end

  defp insert_message(agent_id, index, role, text) do
    {1, _} =
      Nest.Repo.insert_all("messages", [
        %{
          agent_id: agent_id,
          message_index: index,
          role: role,
          content: %{"parts" => [%{"kind" => "text", "text" => text}]},
          inserted_at: DateTime.utc_now()
        }
      ])

    :ok
  end

  defp system_text(agent_id), do: text_at(agent_id, 0)

  defp text_at(agent_id, index) do
    Nest.Repo.one!(
      from(m in "messages",
        where: m.agent_id == ^agent_id and m.message_index == ^index,
        select: m.content
      )
    )
    |> Map.fetch!("parts")
    |> Enum.map_join("", &Map.get(&1, "text", ""))
  end

  defp name(space_id, id) do
    Nest.Repo.one!(
      from(a in "agents", where: a.id == ^id and a.space_id == ^space_id, select: a.name)
    )
  end

  defp username(id) do
    Nest.Repo.one!(from(u in "users", where: u.id == ^id, select: u.username))
  end

  defp recorded_agents(space_id) do
    Nest.Repo.all(
      from(m in "lowercase_name_migrations",
        where: m.subject == "agents" and m.space_id == ^space_id,
        order_by: [asc: m.id],
        select: {m.old_name, m.new_name}
      )
    )
  end

  defp recorded_users do
    Nest.Repo.all(
      from(m in "lowercase_name_migrations",
        where: m.subject == "users",
        order_by: [asc: m.id],
        select: {m.old_name, m.new_name}
      )
    )
  end

  # The migration inlines `/tmp` as the sandbox root; `Paths.sandbox_root/0` is
  # the same value, and using it keeps the test honest about which one it means.
  defp tmp_dir(name), do: Path.join(Paths.sandbox_root(), name)

  # An unsafe name (a space and a capital) that folds to a safe one, and whose
  # old and folded forms both carry `@scratch_tag`.
  defp scratch_name, do: "#{@scratch_tag} Scratch #{unique()}"

  # A `"none"` space's scratch as Nest makes it: the directory plus the marker.
  defp marked_scratch(name) do
    dir = tmp_dir(name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, ".nest-scratch"), "")
    on_exit(fn -> remove_scratch_dir(dir) end)
    dir
  end

  # A host directory that merely shares the name: no marker, so not Nest's.
  defp host_dir(name) do
    dir = tmp_dir(name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "host-file"), "not Nest's")
    on_exit(fn -> remove_scratch_dir(dir) end)
    dir
  end

  defp remove_scratch_dir(dir) do
    if String.contains?(dir, @scratch_tag), do: File.rm_rf!(dir)
  end
end
