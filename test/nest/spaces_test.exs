defmodule Nest.SpacesTest do
  @moduledoc """
  Tests for `Nest.Spaces`: the space lifecycle (create, rename, delete, archive,
  unarchive), the two creation gates — the root-agent slug rule and the
  workspace requirement — and the explicit-vocation override on
  `create_space_with_root_agent/2`.

  The blueprint-rooted half of that contract — a caller that names no
  `vocation:` gets the blueprint's `root_vocation` — is covered end-to-end
  through the lobby, in `NestWeb.LobbyChannelTest`'s "blueprint_id drives the
  root agent's vocation over the default". What is left here is the override
  and the refusals.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.Supervisor
  alias Nest.Blueprints
  alias Nest.BlueprintsFixtures
  alias Nest.Persistence
  alias Nest.Spaces
  alias Nest.Spaces.Space
  alias Nest.VocationsFixtures

  setup do
    {:ok, user, _role} =
      Nest.Accounts.create_user(
        %{
          username: "space-test-#{System.unique_integer([:positive])}",
          password: "password123"
        },
        "first-user"
      )

    {:ok, user_id: user.id}
  end

  describe "create_space_with_root_agent/2 with blueprints" do
    test "explicit vocation wins over the blueprint's root_vocation", %{user_id: user_id} do
      blueprint_vocation = VocationsFixtures.vocation_fixture()
      explicit_vocation = VocationsFixtures.vocation_fixture()

      blueprint =
        BlueprintsFixtures.blueprint_fixture(%{root_vocation: blueprint_vocation.slug})

      attrs = %{
        name: "phase2-override-#{System.unique_integer([:positive])}",
        slug: "phase2-override-#{System.unique_integer([:positive])}",
        blueprint_id: blueprint.id,
        vocation: explicit_vocation.slug,
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        workspace_path: AgentTestHelpers.default_test_workspace()
      }

      assert {:ok, %Space{} = space, agent_name} =
               Spaces.create_space_with_root_agent(user_id, attrs)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, agent_name) end)

      {:ok, info} = Agents.get_info(space.id, agent_name)
      assert info.vocation_id == explicit_vocation.id
    end

    test "returns {:error, :blueprint_missing} when blueprint_id is missing", %{user_id: user_id} do
      attrs = %{
        name: "ghost-blueprint-#{System.unique_integer([:positive])}",
        blueprint_id: -1,
        model: %{name: "qwen3.5-plus", provider: "model-studio"}
      }

      assert {:error, :blueprint_missing} =
               Spaces.create_space_with_root_agent(user_id, attrs)
    end

    test "returns {:error, :missing_vocation} when neither vocation nor blueprint given", %{
      user_id: user_id
    } do
      attrs = %{
        name: "no-vocation-#{System.unique_integer([:positive])}",
        model: %{name: "qwen3.5-plus", provider: "model-studio"}
      }

      assert {:error, :missing_vocation} =
               Spaces.create_space_with_root_agent(user_id, attrs)
    end
  end

  describe "create_space_with_root_agent/2 slug validation" do
    test "refuses a slug that could not be the root agent's name", %{user_id: user_id} do
      vocation = VocationsFixtures.vocation_fixture()

      # The root agent is named `<slug>-root` (`root_agent_name/2`) and an
      # agent's name doubles as its scratch-directory segment, so a slug has to
      # be filename-safe. Refusing it here — as a *space* changeset error — is
      # what keeps the lobby's reply generic: otherwise the failure surfaces
      # from the agent changeset as `invalid_agent_name`, which names a field
      # the client never sent (see
      # `NestWeb.LobbyChannel.AgentErrors.create_payload/1`).
      attrs = %{
        name: "My Space #{System.unique_integer([:positive])}",
        slug: "my space",
        vocation: vocation.slug,
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        workspace_path: AgentTestHelpers.default_test_workspace()
      }

      assert {:error, %Ecto.Changeset{data: %Space{}} = changeset} =
               Spaces.create_space_with_root_agent(user_id, attrs)

      assert [slug: {message, _opts}] = changeset.errors
      assert message == "must be usable as an agent name (lowercase letters, digits, `_` and `-`)"

      # The slug is refused before the insert, so the transaction left nothing
      # behind — no space row, and no agent row for it to hang off.
      assert Spaces.list_for_user(user_id) == []
    end

    test "keeps a derived slug (and the name it comes from) working", %{user_id: user_id} do
      # The rule is on the *derived* agent name, not on the slug's own shape, so
      # a slug the server derives from a name still passes: `Slug.from_name/1`
      # collapses everything unsafe to `-`.
      vocation = VocationsFixtures.vocation_fixture()

      attrs = %{
        name: "My Space #{System.unique_integer([:positive])}",
        vocation: vocation.slug,
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        workspace_path: AgentTestHelpers.default_test_workspace()
      }

      assert {:ok, %Space{} = space, agent_name} =
               Spaces.create_space_with_root_agent(user_id, attrs)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, agent_name) end)

      assert agent_name == space.slug <> "-root"
      assert PersistedAgent.valid_name?(agent_name)
    end
  end

  describe "blueprint cascade" do
    test "deleting a blueprint nullifies spaces.blueprint_id (FK on_delete: :nilify_all)", %{
      user_id: user_id
    } do
      blueprint = BlueprintsFixtures.blueprint_fixture()
      attrs = blueprint_space_attrs(blueprint.id)

      assert {:ok, %Space{id: space_id} = space, agent_name} =
               Spaces.create_space_with_root_agent(user_id, attrs)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, agent_name) end)

      assert space.blueprint_id == blueprint.id

      assert {:ok, _} = Blueprints.delete_blueprint(blueprint)

      # The space row is detached, not deleted
      reloaded = Spaces.get_space(space_id)
      assert reloaded.blueprint_id == nil
    end
  end

  describe "delete_space/1 cascade" do
    test "cascades to all agents and the space row", %{user_id: user_id} do
      vid = AgentTestHelpers.vocation_id_for_test()

      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user_id, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: "delete-cascade-#{System.unique_integer([:positive])}"
        })

      model = %{name: "qwen3.5-plus", provider: "model-studio"}
      agent_a = "agent-a-#{System.unique_integer([:positive])}"
      agent_b = "agent-b-#{System.unique_integer([:positive])}"

      assert {:ok, ^agent_a} =
               Agents.create_agent(space_id, model, name: agent_a, vocation_id: vid)

      assert {:ok, ^agent_b} =
               Agents.create_agent(space_id, model, name: agent_b, vocation_id: vid)

      # Defensive cleanup if the assertions below fail before the
      # delete runs.
      on_exit(fn ->
        _ = Supervisor.stop_agent(space_id, agent_a)
        _ = Supervisor.stop_agent(space_id, agent_b)
      end)

      assert :ok = Spaces.delete_space(space_id)

      # Space row gone.
      assert Spaces.get_space(space_id) == nil

      # Agent rows gone and processes terminated.
      assert {:error, :not_found} = Agents.get_info(space_id, agent_a)
      assert {:error, :not_found} = Agents.get_info(space_id, agent_b)
      assert Persistence.fetch_all_agents_for_space(space_id) == []
    end

    test "returns {:error, :not_found} for a missing space" do
      assert {:error, :not_found} = Spaces.delete_space(-1)
    end
  end

  describe "rename_space/2" do
    test "updates the name and re-derives the slug", %{user_id: user_id} do
      {:ok, %Space{id: id}} =
        Spaces.create_space(user_id, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: "original-#{System.unique_integer([:positive])}"
        })

      new_name = "Renamed Space #{System.unique_integer([:positive])}"

      assert {:ok, %Space{name: ^new_name} = updated} =
               Spaces.rename_space(id, %{name: new_name})

      assert updated.slug == slugify(new_name)
    end

    test "returns {:error, :not_found} for a missing space" do
      assert {:error, :not_found} = Spaces.rename_space(-1, %{name: "x"})
    end

    test "rejects a name that collides with another space", %{user_id: user_id} do
      name_a = "space-a-#{System.unique_integer([:positive])}"

      {:ok, %Space{}} =
        Spaces.create_space(user_id, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: name_a
        })

      {:ok, %Space{id: id_b}} =
        Spaces.create_space(user_id, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: "space-b-#{System.unique_integer([:positive])}"
        })

      # Renaming space B to A's exact name collides on the unique
      # `name` index (the auto-derived slug would also collide with
      # A's slug, but the name constraint fires first).
      assert {:error, %Ecto.Changeset{} = cs} = Spaces.rename_space(id_b, %{name: name_a})
      assert errors_on(cs).name != []
    end
  end

  describe "archive_space/1 and unarchive_space/1" do
    test "archiving stops the space's running agents but does not mark them archived",
         %{user_id: user_id} do
      vid = AgentTestHelpers.vocation_id_for_test()

      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user_id, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: "arch-stop-#{System.unique_integer([:positive])}"
        })

      model = %{name: "qwen3.5-plus", provider: "model-studio"}
      agent_a = "arch-agent-a-#{System.unique_integer([:positive])}"

      assert {:ok, ^agent_a} =
               Agents.create_agent(space_id, model, name: agent_a, vocation_id: vid)

      assert {:ok, pid} = Agents.Registry.lookup(space_id, agent_a)
      ref = Process.monitor(pid)

      assert :ok = Spaces.archive_space(space_id)

      # The agent process is terminated. Monitor + DOWN is deterministic
      # (a raw Registry lookup races the teardown/registry cleanup).
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      # Agent row still present and NOT marked archived — unarchive restores it.
      assert {:ok, %Nest.Agents.PersistedAgent{archived: false}} =
               Persistence.fetch_agent(space_id, agent_a)
    end

    test "the flag goes up before the space's agents are stopped", %{user_id: user_id} do
      # The ordering is the whole fix for the start race in
      # `Nest.Agents.Supervisor.fetch_or_start_agent/2`: a start verifies the flag
      # *after* its process exists, so a row inserted after this sweep has read
      # the space's rows has to find the flag already set. Stopping first left
      # that window as wide as the sweep — and `remove_sandbox/1` sits inside it.
      vid = AgentTestHelpers.vocation_id_for_test()
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user_id, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: "arch-order-#{System.unique_integer([:positive])}"
        })

      name = "arch-order-agent-#{System.unique_integer([:positive])}"
      assert {:ok, ^name} = Agents.create_agent(space_id, model, name: name, vocation_id: vid)

      # Stopped for real, so what the sweep sees is a row with no process — the
      # ordinary case for archiving a space nobody is using right now.
      assert :ok = Supervisor.stop_agent(space_id, name)

      Mimic.stub(Nest.Agents.Supervisor, :stop_agent, fn id, stopped ->
        send(self(), {:stopping, stopped, Spaces.archived?(id)})
        :ok
      end)

      assert :ok = Spaces.archive_space(space_id)

      assert_received {:stopping, ^name, true}
    end

    test "an agent created after its space is archived is refused, and leaves no row",
         %{user_id: user_id} do
      vid = AgentTestHelpers.vocation_id_for_test()
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user_id, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: "arch-late-#{System.unique_integer([:positive])}"
        })

      assert :ok = Spaces.archive_space(space_id)

      name = "arch-late-agent-#{System.unique_integer([:positive])}"

      # `PreSpawn.pre_spawn/1` writes the row before the process exists, so a
      # start that finds its space archived rolls that row back rather than
      # leaving an orphan — and says so, which is why this is captured rather
      # than printed.
      log =
        capture_log(fn ->
          assert {:error, :space_archived} =
                   Agents.create_agent(space_id, model, name: name, vocation_id: vid)
        end)

      assert log =~ ":space_archived"
      assert log =~ "removing the row it pre-spawned"
      assert Persistence.fetch_agent(space_id, name) == {:error, :not_found}
      assert Agents.Registry.lookup(space_id, name) == {:error, :not_found}
    end

    test "an archived space's agent is not started on demand", %{user_id: user_id} do
      vid = AgentTestHelpers.vocation_id_for_test()
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user_id, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: "arch-reload-#{System.unique_integer([:positive])}"
        })

      name = "arch-reload-agent-#{System.unique_integer([:positive])}"
      assert {:ok, ^name} = Agents.create_agent(space_id, model, name: name, vocation_id: vid)

      assert :ok = Spaces.archive_space(space_id)

      # The row is the space's, and archiving keeps it — only the process is
      # refused. Unarchiving rehydrates it as usual.
      assert {:error, :space_archived} =
               Supervisor.fetch_or_start_agent(space_id, %{name: name})

      assert Agents.Registry.lookup(space_id, name) == {:error, :not_found}

      assert {:ok, %Nest.Agents.PersistedAgent{archived: false}} =
               Persistence.fetch_agent(space_id, name)
    end

    test "archiving other users' spaces is not possible via list queries (owner-only listing)",
         %{user_id: user_id} do
      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user_id, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: "arch-owner-#{System.unique_integer([:positive])}"
        })

      assert :ok = Spaces.archive_space(space_id)

      # A different user sees neither the active nor archived space.
      other_id = user_id + 10_000
      assert Spaces.list_for_user(other_id) == []
      assert Spaces.list_archived_for_user(other_id) == []
    end

    test "returns {:error, :not_found} for a missing space" do
      assert {:error, :not_found} = Spaces.archive_space(-1)
      assert {:error, :not_found} = Spaces.unarchive_space(-1)
    end
  end

  # Helpers

  # Mirror the slug generator in `Nest.Slug` so the rename assertion
  # states the expected slug instead of reading it back from the row.
  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp blueprint_space_attrs(blueprint_id) do
    %{
      name: "blueprint-attrs-#{System.unique_integer([:positive])}",
      slug: "blueprint-attrs-#{System.unique_integer([:positive])}",
      blueprint_id: blueprint_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      workspace_path: AgentTestHelpers.default_test_workspace()
    }
  end

  describe "create_space_with_root_agent/2 workspace validation" do
    setup do
      {:ok, vocation} =
        Nest.Vocations.create_vocation(%{
          name: "WS Root #{System.unique_integer([:positive])}",
          description: "writes workspace",
          system_prompt: "ws",
          tools: []
        })

      base = %{
        name: "ws-root-#{System.unique_integer([:positive])}",
        slug: "ws-root-#{System.unique_integer([:positive])}",
        vocation: vocation.slug,
        model: %{name: "qwen3.5-plus", provider: "model-studio"}
      }

      %{base: base}
    end

    test "rejects a missing or /tmp-rooted workspace", %{user_id: user_id, base: base} do
      assert {:error, :workspace_required} =
               Spaces.create_space_with_root_agent(user_id, base)

      assert {:error, :workspace_under_tmp} =
               Spaces.create_space_with_root_agent(
                 user_id,
                 Map.put(base, :workspace_path, "/tmp/ws")
               )

      assert {:error, :workspace_missing} =
               Spaces.create_space_with_root_agent(
                 user_id,
                 Map.put(base, :workspace_path, "/nope/missing-ws")
               )
    end
  end

  describe "create_space/2 workspace requirement" do
    test "refuses an insert with no workspace, and leaves the update path permissive" do
      # The invariant belongs to the *insert* changeset: a space row with no
      # workspace is not a space this build can run, so no new one may be one.
      # `rename_space/1` goes through `changeset/2` instead, which must keep
      # accepting a row a previous build left without a workspace — that is why
      # the requirement is not there.
      name = "no-ws-#{System.unique_integer([:positive])}"

      assert {:error, changeset} = Spaces.create_space(nil, %{name: name})
      assert {"can't be blank", _meta} = changeset.errors[:workspace_path]
      assert Spaces.get_by_name(name) == nil

      legacy =
        Repo.insert!(%Space{
          name: "legacy-#{System.unique_integer([:positive])}",
          slug: "legacy-#{System.unique_integer([:positive])}",
          workspace_path: nil
        })

      assert {:ok, renamed} = Spaces.rename_space(legacy.id, %{name: "renamed-legacy"})
      assert renamed.workspace_path == nil
    end
  end
end
