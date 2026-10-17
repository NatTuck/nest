defmodule Nest.Agents.AgentNameMigrationTest do
  @moduledoc """
  Tests for the `sanitize_agent_names` data migration, which brings
  pre-existing `agents.name` rows up to the `[A-Za-z0-9_-]+` / 255-byte
  rule `PersistedAgent.changeset/2` now enforces.

  The migration file lives in `priv/repo/migrations/` (a `.exs` script,
  not compiled into the app), so this suite `Code.require_file/1`s it and
  drives its two data functions directly against rows it inserted. The
  DDL half of `up/0` already ran: `mix test` migrates the test database
  before the suite starts.

  `async: true` — every test inserts its own agents into its own space and
  the SQL sandbox rolls the rewrites back.
  """
  use Nest.DataCase, async: true

  import Ecto.Query

  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Sandbox.Mounts

  @migration_file "priv/repo/migrations/20261011000000_sanitize_agent_names.exs"

  # The migration is a `.exs` script under `priv/`, so it is not compiled
  # with the app: it is loaded at runtime — by `mix ecto.migrate` before the
  # suite runs, or by the `Code.require_file/1` in `setup_all` below. Silence
  # the compile-time "module is not available" warning for the calls to it.
  @compile {:no_warn_undefined, Nest.Repo.Migrations.SanitizeAgentNames}

  setup_all do
    # `mix test` (via the `test` alias in mix.exs) migrates the test
    # database first, which already loads this module into the BEAM. Only
    # require the file when that has not happened.
    unless Code.ensure_loaded?(Nest.Repo.Migrations.SanitizeAgentNames) do
      Code.require_file(@migration_file)
    end

    :ok
  end

  # The migration module, defined by the `Code.require_file/1` above.
  defp migration, do: Nest.Repo.Migrations.SanitizeAgentNames

  defp sanitize_names, do: migration().sanitize_names()

  defp restore_names, do: migration().restore_names()

  describe "up (rewriting existing names)" do
    test "rewrites an unsafe name to a readable, safe equivalent" do
      space_id = space()
      id = insert(space_id, "My Agent")

      sanitize_names()

      assert name(space_id, id) == "my-agent"
      assert recorded(space_id) == [{"My Agent", "my-agent"}]
    end

    test "folds accented letters instead of dropping them" do
      space_id = space()
      id = insert(space_id, "Café ☕")

      sanitize_names()

      assert name(space_id, id) == "cafe"
    end

    test "falls back to `agent` when nothing survives the fold" do
      space_id = space()
      id = insert(space_id, "漢字")

      sanitize_names()

      assert name(space_id, id) == "agent"
    end

    test "leaves an already-safe name untouched and records nothing" do
      space_id = space()
      id = insert(space_id, "already-safe_1")

      sanitize_names()

      assert name(space_id, id) == "already-safe_1"
      assert recorded(space_id) == []
    end

    test "disambiguates two unsafe names that fold to the same candidate" do
      space_id = space()
      first = insert(space_id, "Foo Bar")
      second = insert(space_id, "foo-bar!")

      sanitize_names()

      # `id` order decides who keeps the clean fold.
      assert name(space_id, first) == "foo-bar"
      assert name(space_id, second) =~ ~r/\Afoo-bar-[0-9a-f]{6}\z/
    end

    test "never steals a name another row already holds" do
      space_id = space()
      keeper = insert(space_id, "foo-bar")
      folded = insert(space_id, "Foo Bar")

      sanitize_names()

      assert name(space_id, keeper) == "foo-bar"
      assert name(space_id, folded) =~ ~r/\Afoo-bar-[0-9a-f]{6}\z/
    end

    test "scopes uniqueness to a space: the same unsafe name folds cleanly in both" do
      mine = space()
      theirs = space()
      mine_id = insert(mine, "Shared Name")
      theirs_id = insert(theirs, "Shared Name")

      sanitize_names()

      # No digest suffix: `(space_id, name)` is the unique key, so the two
      # rows never see each other.
      assert name(mine, mine_id) == "shared-name"
      assert name(theirs, theirs_id) == "shared-name"
    end

    test "truncates the base to keep a disambiguated name within the component limit" do
      space_id = space()
      keeper = insert(space_id, String.duplicate("a", 250))
      # 250 characters (the column's limit is characters, not bytes) that
      # fold to the keeper's name.
      folded = insert(space_id, String.duplicate("à", 250))

      sanitize_names()

      assert name(space_id, keeper) == String.duplicate("a", 250)

      candidate = name(space_id, folded)
      assert byte_size(candidate) == 255
      assert candidate =~ ~r/\A[a]{248}-[0-9a-f]{6}\z/
    end

    test "is idempotent" do
      space_id = space()
      id = insert(space_id, "Idempotent Agent")

      sanitize_names()
      after_first = name(space_id, id)
      recorded_after_first = recorded(space_id)

      sanitize_names()

      assert name(space_id, id) == after_first
      assert recorded(space_id) == recorded_after_first
    end
  end

  describe "the agent's own system message" do
    test "is rewritten to the new name and scratch dir" do
      space_id = space()
      id = insert(space_id, "Foo Bar")
      insert_system_message(id, "Foo Bar")

      sanitize_names()

      assert name(space_id, id) == "foo-bar"

      text = system_text(id)
      assert text =~ ~s(Your name is "foo-bar")
      assert text =~ "Your own scratch directory is `/tmp/foo-bar/`"
      refute text =~ "Foo Bar"
      refute text =~ "/tmp/Foo Bar/"
    end

    test "leaves text that is not one of the two renderings alone" do
      space_id = space()
      id = insert(space_id, "Foo Bar")

      insert_system_message(id, "Foo Bar",
        extra: "\n\nAn AGENTS.md excerpt mentions the agent Foo Bar by name."
      )

      sanitize_names()

      text = system_text(id)
      assert text =~ ~s(Your name is "foo-bar")

      # Prose is not a rendering the composer emits, so it is untouched: a
      # general search-and-replace of the old name would have rewritten it.
      assert text =~ "mentions the agent Foo Bar by name"
    end

    test "only the index-0 system row is touched" do
      space_id = space()
      id = insert(space_id, "Foo Bar")
      insert_system_message(id, "Foo Bar")
      # A later row that happens to carry the same sentence is a transcript,
      # not the prompt: leave it alone.
      insert_message(id, 1, "user", ~s(They said: Your name is "Foo Bar"))

      sanitize_names()

      assert system_text(id) =~ ~s(Your name is "foo-bar")
      assert text_at(id, 1) =~ ~s(Your name is "Foo Bar")
    end

    test "is a no-op for an agent with no system row (a clone owns none)" do
      space_id = space()
      id = insert(space_id, "Clone Name")

      sanitize_names()

      assert name(space_id, id) == "clone-name"
      assert Nest.Repo.all(from(m in "messages", where: m.agent_id == ^id, select: m.id)) == []
    end
  end

  describe "down (restoring the original names)" do
    test "restores every recorded name" do
      space_id = space()
      id = insert(space_id, "Restore Me")

      sanitize_names()
      assert name(space_id, id) == "restore-me"

      restore_names()

      assert name(space_id, id) == "Restore Me"
    end

    test "restores the original system-message text" do
      space_id = space()
      id = insert(space_id, "Foo Bar")
      insert_system_message(id, "Foo Bar")
      original = system_text(id)

      sanitize_names()
      refute system_text(id) == original

      restore_names()

      assert name(space_id, id) == "Foo Bar"
      assert system_text(id) == original
      assert system_text(id) =~ ~s(Your name is "Foo Bar")
    end

    test "is a no-op for a row the migration never touched" do
      space_id = space()
      id = insert(space_id, "untouched_1")

      sanitize_names()
      restore_names()

      assert name(space_id, id) == "untouched_1"
    end
  end

  defp space do
    {:ok, space} =
      Nest.Spaces.create_space(nil, %{
        name: "sanitize-names-#{System.unique_integer([:positive])}",
        slug: "sanitize-names-#{System.unique_integer([:positive])}"
      })

    space.id
  end

  # Insert an agent row with an arbitrary (possibly unsafe) name. The
  # changeset now refuses those names, so the row goes in through
  # `insert_all`, which is also how the rows this migration exists for got
  # there.
  defp insert(space_id, name) do
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

  defp vocation do
    {:ok, vocation} =
      Nest.Vocations.upsert_vocation(%{
        name: "Sanitize Names Test",
        description: "Default for the agent-name migration test",
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
        0,
        Nest.Modes.act()
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

  defp recorded(space_id) do
    Nest.Repo.all(
      from(m in "agent_name_migrations",
        where: m.space_id == ^space_id,
        order_by: [asc: m.id],
        select: {m.old_name, m.new_name}
      )
    )
  end
end
