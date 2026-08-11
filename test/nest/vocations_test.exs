defmodule Nest.VocationsTest do
  use Nest.DataCase, async: true

  alias Nest.Vocations
  alias Nest.Vocations.Vocation

  import Nest.VocationsFixtures

  describe "vocations" do
    @invalid_attrs %{name: nil, description: nil, modes: nil, tools: nil, system_prompt: nil}

    test "list_vocations/0 includes the created vocation" do
      vocation = vocation_fixture()
      # Pre-existing test data may be present in the DB (the SQL
      # sandbox rolls back per-test, but auto-increment ids do not
      # reset between runs), so we check membership rather than
      # list-equality.
      assert vocation in Vocations.list_vocations()
    end

    test "get_vocation!/1 returns the vocation with given id" do
      vocation = vocation_fixture()
      assert Vocations.get_vocation!(vocation.id) == vocation
    end

    test "create_vocation/1 with valid data creates a vocation" do
      valid_attrs = %{
        name: "some name",
        description: "some description",
        modes: %{},
        tools: [],
        system_prompt: "some system_prompt"
      }

      assert {:ok, %Vocation{} = vocation} = Vocations.create_vocation(valid_attrs)
      assert vocation.name == "some name"
      assert vocation.description == "some description"
      assert vocation.modes == %{}
      assert vocation.tools == []
      assert vocation.system_prompt == "some system_prompt"
    end

    test "create_vocation/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Vocations.create_vocation(@invalid_attrs)
    end

    test "update_vocation/2 with valid data updates the vocation" do
      vocation = vocation_fixture()

      update_attrs = %{
        name: "some updated name",
        description: "some updated description",
        modes: %{},
        tools: [],
        system_prompt: "some updated system_prompt"
      }

      assert {:ok, %Vocation{} = vocation} = Vocations.update_vocation(vocation, update_attrs)
      assert vocation.name == "some updated name"
      assert vocation.description == "some updated description"
      assert vocation.modes == %{}
      assert vocation.tools == []
      assert vocation.system_prompt == "some updated system_prompt"
    end

    test "update_vocation/2 with invalid data returns error changeset" do
      vocation = vocation_fixture()
      assert {:error, %Ecto.Changeset{}} = Vocations.update_vocation(vocation, @invalid_attrs)
      assert vocation == Vocations.get_vocation!(vocation.id)
    end

    test "delete_vocation/1 deletes the vocation" do
      vocation = vocation_fixture()
      assert {:ok, %Vocation{}} = Vocations.delete_vocation(vocation)
      assert_raise Ecto.NoResultsError, fn -> Vocations.get_vocation!(vocation.id) end
    end

    test "delete_vocation/1 returns :agents_using_vocation when an agent references the vocation" do
      # `agents.vocation_id` is `NOT NULL` with `ON DELETE RESTRICT`,
      # so deleting a vocation that any agent references is
      # rejected. The Vocations context catches this before the
      # DELETE and returns a friendly error.
      vocation = vocation_fixture()

      {:ok, space} =
        Nest.Spaces.create_space(nil, %{
          name: "voc-test-#{System.unique_integer([:positive])}",
          slug: "voc-test-#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        Nest.Persistence.insert_agent(%{
          space_id: space.id,
          name: "uses-#{System.unique_integer([:positive])}",
          model: %{name: "test"},
          vocation_id: vocation.id
        })

      assert {:error, :agents_using_vocation} = Vocations.delete_vocation(vocation)
      # The vocation is still present.
      assert fetched = Vocations.get_vocation(vocation.id)
      assert fetched.id == vocation.id
    end

    test "change_vocation/1 returns a vocation changeset" do
      vocation = vocation_fixture()
      assert %Ecto.Changeset{} = Vocations.change_vocation(vocation)
    end

    test "upsert_vocation/1 inserts when no row exists for the name" do
      attrs = %{
        name: "upsert-new-#{System.unique_integer([:positive])}",
        description: "first version",
        system_prompt: "original prompt",
        tools: [],
        modes: %{}
      }

      assert {:ok, %Vocation{id: id}} = Vocations.upsert_vocation(attrs)
      assert is_integer(id)

      assert %Vocation{description: "first version", system_prompt: "original prompt"} =
               Vocations.get_vocation!(id)
    end

    test "upsert_vocation/1 updates the existing row when the name already exists" do
      original =
        vocation_fixture(%{
          description: "first version",
          system_prompt: "original prompt"
        })

      updated_attrs = %{
        name: original.name,
        description: "updated version",
        system_prompt: "updated prompt",
        tools: original.tools,
        modes: original.modes
      }

      assert {:ok, %Vocation{} = updated} = Vocations.upsert_vocation(updated_attrs)

      # `id` is preserved so any `agents.vocation_id` FK references
      # stay valid across the re-seed.
      assert updated.id == original.id
      assert updated.description == "updated version"
      assert updated.system_prompt == "updated prompt"
    end

    test "upsert_vocation/1 returns the validation changeset when attrs are invalid" do
      assert {:error, %Ecto.Changeset{}} =
               Vocations.upsert_vocation(%{
                 name: nil,
                 description: nil,
                 system_prompt: nil,
                 tools: nil,
                 modes: nil
               })
    end
  end
end
