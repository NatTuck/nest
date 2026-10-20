defmodule Nest.BlueprintsTest do
  use Nest.DataCase, async: true

  alias Nest.Blueprints
  alias Nest.Blueprints.Blueprint
  alias Nest.BlueprintsFixtures
  alias Nest.VocationsFixtures

  describe "blueprints" do
    test "create_blueprint/1 derives slug from name when omitted" do
      vocation = VocationsFixtures.vocation_fixture()
      n = System.unique_integer([:positive])

      {:ok, %Blueprint{slug: slug}} =
        Blueprints.create_blueprint(%{
          name: "My Cool Blueprint #{n}",
          root_vocation: vocation.slug
        })

      assert slug == "my-cool-blueprint-#{n}"
    end

    test "create_blueprint/1 rejects missing root_vocation" do
      attrs = %{name: "no-root-#{System.unique_integer([:positive])}"}
      assert {:error, %Ecto.Changeset{} = cs} = Blueprints.create_blueprint(attrs)
      assert "can't be blank" in errors_on(cs).root_vocation
    end

    test "create_blueprint/1 rejects duplicate name" do
      vocation = VocationsFixtures.vocation_fixture()
      name = "dup-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               Blueprints.create_blueprint(%{
                 name: name,
                 root_vocation: vocation.slug
               })

      assert {:error, cs} =
               Blueprints.create_blueprint(%{
                 name: name,
                 root_vocation: vocation.slug
               })

      assert "has already been taken" in errors_on(cs).name
    end

    test "create_blueprint/1 rejects malformed spawnable_vocations" do
      vocation = VocationsFixtures.vocation_fixture()

      for spawnable_vocations <- [[123], [vocation.slug, vocation.slug]] do
        assert {:error, cs} =
                 Blueprints.create_blueprint(%{
                   name: "bad-spawnable-#{System.unique_integer([:positive])}",
                   root_vocation: vocation.slug,
                   spawnable_vocations: spawnable_vocations
                 })

        assert errors_on(cs).spawnable_vocations != []
      end
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
          root_vocation: vocation.slug
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
          root_vocation: vocation.slug
        })

      {:ok, %Blueprint{id: same_id} = second} =
        Blueprints.upsert_blueprint(%{
          name: name,
          description: "second",
          root_vocation: vocation.slug
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

  describe "root_vocation_slug_for/1" do
    # The valid-id path is covered end-to-end by `NestWeb.LobbyChannelTest`'s
    # "blueprint_id drives the root agent's vocation over the default".
    test "returns nil when there is no blueprint" do
      assert Blueprints.root_vocation_slug_for(nil) == nil
      assert Blueprints.root_vocation_slug_for(-1) == nil
    end
  end
end
