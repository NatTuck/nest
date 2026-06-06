defmodule Nest.VocationsTest do
  use Nest.DataCase

  alias Nest.Vocations

  describe "vocations" do
    alias Nest.Vocations.Vocation

    import Nest.VocationsFixtures

    @invalid_attrs %{name: nil, description: nil, modes: nil, tools: nil, system_prompt: nil}

    test "list_vocations/0 returns all vocations" do
      vocation = vocation_fixture()
      assert Vocations.list_vocations() == [vocation]
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

    test "change_vocation/1 returns a vocation changeset" do
      vocation = vocation_fixture()
      assert %Ecto.Changeset{} = Vocations.change_vocation(vocation)
    end
  end
end
