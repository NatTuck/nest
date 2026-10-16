defmodule Nest.Spaces.SandboxBackendTest do
  @moduledoc """
  The per-space `sandbox_backend`: its default, its validation, its
  immutability, and the two reads the rest of the system takes of it
  (`sandbox_backend/1` and `none_space_ids/0`).
  """

  use Nest.DataCase, async: true

  alias Nest.Spaces
  alias Nest.Spaces.Space
  alias NestWeb.LobbyChannel.AgentErrors

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "the backend list" do
    test "offers bwrap, docker and none, defaulting to bwrap" do
      assert Space.sandbox_backends() == ~w(bwrap docker none)
      assert Space.default_sandbox_backend() == "bwrap"
      assert Space.default_sandbox_backend() in Space.sandbox_backends()
    end
  end

  describe "create_space/2" do
    test "defaults the backend to bwrap" do
      assert {:ok, %Space{sandbox_backend: "bwrap"}} =
               Spaces.create_space(nil, %{name: unique("sb-default")})
    end

    test "keeps an explicit backend" do
      assert {:ok, %Space{sandbox_backend: "none"}} =
               Spaces.create_space(nil, %{name: unique("sb-none"), sandbox_backend: "none"})
    end

    test "treats a blank backend as absent" do
      for blank <- [nil, ""] do
        assert {:ok, %Space{sandbox_backend: "bwrap"}} =
                 Spaces.create_space(nil, %{
                   name: unique("sb-blank"),
                   sandbox_backend: blank
                 })
      end
    end

    test "refuses a backend this build does not implement" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Spaces.create_space(nil, %{name: unique("sb-bad"), sandbox_backend: "podman"})

      assert {"must be one of bwrap, docker, none", _meta} =
               changeset.errors[:sandbox_backend]
    end

    test "carries the backend into the JSON a client sees" do
      {:ok, space} = Spaces.create_space(nil, %{name: unique("sb-json"), sandbox_backend: "none"})

      assert Jason.encode!(space) =~ ~s("sandbox_backend":"none")
    end
  end

  describe "immutability" do
    test "rename_space/2 cannot move a space between backends" do
      {:ok, space} =
        Spaces.create_space(nil, %{name: unique("sb-keep"), sandbox_backend: "none"})

      assert {:ok, renamed} =
               Spaces.rename_space(space.id, %{
                 name: unique("sb-renamed"),
                 sandbox_backend: "bwrap"
               })

      assert renamed.sandbox_backend == "none"
      assert Spaces.get_space(space.id).sandbox_backend == "none"
    end
  end

  describe "sandbox_backend/1" do
    test "resolves the space's backend" do
      {:ok, space} = Spaces.create_space(nil, %{name: unique("sb-read"), sandbox_backend: "none"})

      assert Spaces.sandbox_backend(space.id) == "none"
    end

    test "resolves a missing row to the default rather than raising" do
      assert Spaces.sandbox_backend(-1) == Space.default_sandbox_backend()
    end
  end

  describe "none_space_ids/0" do
    test "lists exactly the none-backend spaces" do
      {:ok, none_space} =
        Spaces.create_space(nil, %{name: unique("sb-ids-none"), sandbox_backend: "none"})

      {:ok, bwrap_space} = Spaces.create_space(nil, %{name: unique("sb-ids-bwrap")})

      ids = Spaces.none_space_ids()

      assert MapSet.member?(ids, none_space.id)
      refute MapSet.member?(ids, bwrap_space.id)
    end
  end

  describe "AgentErrors.create_payload/1" do
    test "names the other space in the scratch-name collision" do
      assert {:error, %{"reason" => "scratch_name_in_use", "space_name" => "other-space"}} =
               AgentErrors.create_payload({:scratch_name_in_use, "other-space"})
    end
  end
end
