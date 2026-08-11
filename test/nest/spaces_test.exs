defmodule Nest.SpacesTest do
  @moduledoc """
  Tests for `Nest.Spaces` — focused on the Phase 2 contract
  that `create_space_with_root_agent/2` resolves the root
  agent's `vocation_id` from the supplied `blueprint_id`
  when the caller doesn't pass an explicit `vocation_id:`.

  Earlier Phase 1 work covered `create_space/2`,
  `ensure_primary_space/1`, and `delete_space/1`. These
  tests cover the Phase 2 surface area added by the
  blueprints work.
  """
  use Nest.DataCase, async: true

  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
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
    test "uses the blueprint's root_vocation_id when caller omits vocation_id", %{
      user_id: user_id
    } do
      vocation = VocationsFixtures.vocation_fixture()
      blueprint = BlueprintsFixtures.blueprint_fixture(%{root_vocation_id: vocation.id})

      attrs = %{
        name: "phase2-#{System.unique_integer([:positive])}",
        slug: "phase2-#{System.unique_integer([:positive])}",
        blueprint_id: blueprint.id,
        model: %{name: "qwen3.5-plus", provider: "model-studio"}
      }

      assert {:ok, %Space{} = space, agent_name} =
               Spaces.create_space_with_root_agent(user_id, attrs)

      assert space.blueprint_id == blueprint.id

      # Cleanup the spawned agent
      on_exit(fn -> _ = Supervisor.stop_agent(space.id, agent_name) end)

      # The root agent carries the blueprint's vocation
      {:ok, info} = Agents.get_info(space.id, agent_name)
      assert info.vocation_id == vocation.id
    end

    test "explicit vocation_id wins over the blueprint's root_vocation_id", %{user_id: user_id} do
      blueprint_vocation = VocationsFixtures.vocation_fixture()
      explicit_vocation = VocationsFixtures.vocation_fixture()

      blueprint = BlueprintsFixtures.blueprint_fixture(%{root_vocation_id: blueprint_vocation.id})

      attrs = %{
        name: "phase2-override-#{System.unique_integer([:positive])}",
        slug: "phase2-override-#{System.unique_integer([:positive])}",
        blueprint_id: blueprint.id,
        vocation_id: explicit_vocation.id,
        model: %{name: "qwen3.5-plus", provider: "model-studio"}
      }

      assert {:ok, %Space{} = space, agent_name} =
               Spaces.create_space_with_root_agent(user_id, attrs)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, agent_name) end)

      {:ok, info} = Agents.get_info(space.id, agent_name)
      assert info.vocation_id == explicit_vocation.id
      refute info.vocation_id == blueprint_vocation.id
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

    test "without a blueprint_id, uses the explicit vocation_id", %{user_id: user_id} do
      # Phase 1 contract: a caller without a blueprint supplies
      # `vocation_id` directly; `Agents.create_agent/3` does not
      # fall back to the first available vocation on its own.
      vocation = VocationsFixtures.vocation_fixture()

      attrs = %{
        name: "no-blueprint-#{System.unique_integer([:positive])}",
        vocation_id: vocation.id,
        model: %{name: "qwen3.5-plus", provider: "model-studio"}
      }

      assert {:ok, %Space{blueprint_id: nil} = space, agent_name} =
               Spaces.create_space_with_root_agent(user_id, attrs)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, agent_name) end)

      {:ok, info} = Agents.get_info(space.id, agent_name)
      assert info.vocation_id == vocation.id
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

  describe "blueprint cascade" do
    test "deleting a blueprint nullifies spaces.blueprint_id (FK on_delete: :nilify_all)", %{
      user_id: user_id
    } do
      blueprint = BlueprintsFixtures.blueprint_fixture()
      attrs = blueprint_space_attrs(blueprint.id, user_id)

      assert {:ok, %Space{id: space_id} = space, agent_name} =
               Spaces.create_space_with_root_agent(user_id, attrs)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, agent_name) end)

      assert space.blueprint_id == blueprint.id

      assert {:ok, _} = Blueprints.delete_blueprint(blueprint)

      # The space row is detached, not deleted
      reloaded = Spaces.get_space(space_id)
      assert reloaded != nil
      assert reloaded.blueprint_id == nil
    end
  end

  describe "delete_space/1 cascade" do
    test "cascades to all agents and the space row", %{user_id: user_id} do
      vid = AgentTestHelpers.vocation_id_for_test()

      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user_id, %{
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

      # Both agents are running.
      assert {:ok, _} = Agents.get_info(space_id, agent_a)
      assert {:ok, _} = Agents.get_info(space_id, agent_b)

      assert :ok = Spaces.delete_space(space_id)

      # Space row gone.
      assert Spaces.get_space(space_id) == nil

      # Agent rows gone and processes terminated.
      assert {:error, :not_found} = Agents.get_info(space_id, agent_a)
      assert {:error, :not_found} = Agents.get_info(space_id, agent_b)
      assert Persistence.fetch_all_agents_for_space(space_id) == []
    end

    test "deleting an empty space succeeds", %{user_id: user_id} do
      {:ok, %Space{id: space_id}} =
        Spaces.create_space(user_id, %{name: "empty-del-#{System.unique_integer([:positive])}"})

      assert :ok = Spaces.delete_space(space_id)
      assert Spaces.get_space(space_id) == nil
    end

    test "returns {:error, :not_found} for a missing space" do
      assert {:error, :not_found} = Spaces.delete_space(-1)
    end
  end

  describe "rename_space/2" do
    test "updates the name and re-derives the slug", %{user_id: user_id} do
      {:ok, %Space{id: id}} =
        Spaces.create_space(user_id, %{name: "original-#{System.unique_integer([:positive])}"})

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

      {:ok, %Space{}} = Spaces.create_space(user_id, %{name: name_a})

      {:ok, %Space{id: id_b}} =
        Spaces.create_space(user_id, %{name: "space-b-#{System.unique_integer([:positive])}"})

      # Renaming space B to A's exact name collides on the unique
      # `name` index (the auto-derived slug would also collide with
      # A's slug, but the name constraint fires first).
      assert {:error, %Ecto.Changeset{} = cs} = Spaces.rename_space(id_b, %{name: name_a})
      assert errors_on(cs).name != []
    end
  end

  # Helpers

  # Mirror the slug generator in `Space` so rename assertions
  # don't reimplement the regex.
  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp blueprint_space_attrs(blueprint_id, _user_id) do
    %{
      name: "blueprint-attrs-#{System.unique_integer([:positive])}",
      slug: "blueprint-attrs-#{System.unique_integer([:positive])}",
      blueprint_id: blueprint_id,
      model: %{name: "qwen3.5-plus", provider: "model-studio"}
    }
  end
end
