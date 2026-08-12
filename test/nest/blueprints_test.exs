defmodule Nest.BlueprintsTest do
  use Nest.DataCase, async: true

  alias Nest.Blueprints
  alias Nest.Blueprints.Blueprint
  alias Nest.BlueprintsFixtures
  alias Nest.VocationsFixtures

  describe "blueprints" do
    test "create_blueprint/1 with valid data creates a blueprint" do
      vocation = VocationsFixtures.vocation_fixture()

      valid_attrs = %{
        name: "blueprint-#{System.unique_integer([:positive])}",
        description: "Test blueprint",
        root_vocation_id: vocation.id,
        spawnable_vocation_ids: []
      }

      assert {:ok, %Blueprint{} = blueprint} = Blueprints.create_blueprint(valid_attrs)
      assert blueprint.name == valid_attrs.name
      assert blueprint.root_vocation_id == vocation.id
      # `slug` is auto-generated from `:name` when omitted
      assert is_binary(blueprint.slug) and blueprint.slug != ""
    end

    test "create_blueprint/1 derives slug from name when omitted" do
      vocation = VocationsFixtures.vocation_fixture()
      name = "My Cool Blueprint #{System.unique_integer([:positive])}"

      {:ok, %Blueprint{slug: slug}} =
        Blueprints.create_blueprint(%{
          name: name,
          root_vocation_id: vocation.id
        })

      assert slug == suffix(name)
    end

    test "create_blueprint/1 rejects missing root_vocation_id" do
      attrs = %{name: "no-root-#{System.unique_integer([:positive])}"}
      assert {:error, %Ecto.Changeset{} = cs} = Blueprints.create_blueprint(attrs)
      assert "can't be blank" in errors_on(cs).root_vocation_id
    end

    test "create_blueprint/1 rejects duplicate name" do
      vocation = VocationsFixtures.vocation_fixture()
      name = "dup-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Blueprints.create_blueprint(%{
                 name: name,
                 root_vocation_id: vocation.id
               })

      assert {:error, cs} =
               Blueprints.create_blueprint(%{
                 name: name,
                 root_vocation_id: vocation.id
               })

      assert "has already been taken" in errors_on(cs).name
    end

    test "create_blueprint/1 rejects spawnable_vocation_ids with non-integers" do
      vocation = VocationsFixtures.vocation_fixture()

      assert {:error, cs} =
               Blueprints.create_blueprint(%{
                 name: "bad-spawnable-#{System.unique_integer([:positive])}",
                 root_vocation_id: vocation.id,
                 spawnable_vocation_ids: ["not-an-int"]
               })

      assert errors_on(cs).spawnable_vocation_ids != []
    end

    test "create_blueprint/1 rejects duplicate spawnable_vocation_ids" do
      vocation = VocationsFixtures.vocation_fixture()

      assert {:error, cs} =
               Blueprints.create_blueprint(%{
                 name: "dup-spawnable-#{System.unique_integer([:positive])}",
                 root_vocation_id: vocation.id,
                 spawnable_vocation_ids: [vocation.id, vocation.id]
               })

      assert errors_on(cs).spawnable_vocation_ids != []
    end

    test "get_blueprint/1 returns nil for missing id" do
      assert Blueprints.get_blueprint(-1) == nil
    end

    test "get_by_slug/1 returns the blueprint" do
      vocation = VocationsFixtures.vocation_fixture()
      name = "by-slug-#{System.unique_integer([:positive])}"

      {:ok, %Blueprint{} = blueprint} =
        Blueprints.create_blueprint(%{
          name: name,
          root_vocation_id: vocation.id
        })

      assert Blueprints.get_by_slug(blueprint.slug).id == blueprint.id
      assert Blueprints.get_by_slug("nonexistent-slug") == nil
    end

    test "list_blueprints/0 returns all blueprints ordered by name" do
      _a =
        BlueprintsFixtures.blueprint_fixture(%{name: "a-#{System.unique_integer([:positive])}"})

      _b =
        BlueprintsFixtures.blueprint_fixture(%{name: "b-#{System.unique_integer([:positive])}"})

      names = Blueprints.list_blueprints() |> Enum.map(& &1.name)
      # Both names present and `a-*` sorts before `b-*`
      a_idx = Enum.find_index(names, &String.starts_with?(&1, "a-"))
      b_idx = Enum.find_index(names, &String.starts_with?(&1, "b-"))

      assert a_idx != nil and b_idx != nil
      assert a_idx < b_idx
    end

    test "upsert_blueprint/1 updates in place on rerun" do
      vocation = VocationsFixtures.vocation_fixture()
      name = "upsert-#{System.unique_integer([:positive])}"

      {:ok, %Blueprint{id: id}} =
        Blueprints.upsert_blueprint(%{
          name: name,
          description: "first",
          root_vocation_id: vocation.id
        })

      {:ok, %Blueprint{id: same_id} = second} =
        Blueprints.upsert_blueprint(%{
          name: name,
          description: "second",
          root_vocation_id: vocation.id
        })

      assert id == same_id
      assert second.description == "second"
    end

    test "delete_blueprint/1 removes the blueprint" do
      blueprint = BlueprintsFixtures.blueprint_fixture()
      assert {:ok, %Blueprint{}} = Blueprints.delete_blueprint(blueprint)
      assert Blueprints.get_blueprint(blueprint.id) == nil
    end
  end

  describe "root_vocation_id_for/1" do
    test "returns nil when blueprint id is nil" do
      assert Blueprints.root_vocation_id_for(nil) == nil
    end

    test "returns the root_vocation_id for a valid blueprint id" do
      vocation = VocationsFixtures.vocation_fixture()
      blueprint = BlueprintsFixtures.blueprint_fixture(%{root_vocation_id: vocation.id})

      assert Blueprints.root_vocation_id_for(blueprint.id) == vocation.id
    end

    test "returns nil for a missing blueprint id" do
      assert Blueprints.root_vocation_id_for(-1) == nil
    end
  end

  # Helpers

  # Strip the suffix portion of a slug for assertion in the
  # slug-from-name test. `VocationsFixtures.vocation_fixture/0`
  # produces names like "some name" or "Test Default" so
  # pre-computed slugs are predictable.
  defp suffix(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
