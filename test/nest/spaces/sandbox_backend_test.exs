defmodule Nest.Spaces.SandboxBackendTest do
  @moduledoc """
  The per-space `sandbox_backend`: its default, its validation, its
  immutability, and the two reads the rest of the system takes of it
  (`sandbox_backend/1` and `none_space_ids/0`).
  """

  use Nest.DataCase, async: true

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Sandbox.Backend
  alias Nest.Spaces
  alias Nest.Spaces.Space
  alias NestWeb.LobbyChannel.AgentErrors

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "create_space/2" do
    test "defaults the backend to bwrap" do
      assert {:ok, %Space{sandbox_backend: "bwrap"}} =
               Spaces.create_space(nil, %{
                 workspace_path: AgentTestHelpers.default_test_workspace(),
                 name: unique("sb-default")
               })
    end

    test "keeps an explicit backend" do
      assert {:ok, %Space{sandbox_backend: "none"}} =
               Spaces.create_space(nil, %{
                 workspace_path: AgentTestHelpers.default_test_workspace(),
                 name: unique("sb-none"),
                 sandbox_backend: "none"
               })
    end

    test "treats a blank backend as absent" do
      # The form sends `nil` when the picker is left alone, which is the absent
      # case the test above pins; a raw client can send `""` instead, and it
      # must take the same path rather than failing `validate_required`.
      assert {:ok, %Space{sandbox_backend: "bwrap"}} =
               Spaces.create_space(nil, %{
                 workspace_path: AgentTestHelpers.default_test_workspace(),
                 name: unique("sb-blank"),
                 sandbox_backend: ""
               })
    end

    test "refuses a backend this build does not implement" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Spaces.create_space(nil, %{
                 workspace_path: AgentTestHelpers.default_test_workspace(),
                 name: unique("sb-bad"),
                 sandbox_backend: "podman"
               })

      assert {"must be one of bwrap, docker, none", _meta} =
               changeset.errors[:sandbox_backend]
    end

    test "carries the backend into the JSON a client sees" do
      {:ok, space} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("sb-json"),
          sandbox_backend: "none"
        })

      assert Jason.encode!(space) =~ ~s("sandbox_backend":"none")
    end
  end

  describe "immutability" do
    test "rename_space/2 cannot move a space between backends" do
      {:ok, space} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("sb-keep"),
          sandbox_backend: "none"
        })

      assert {:ok, %Space{}} =
               Spaces.rename_space(space.id, %{
                 name: unique("sb-renamed"),
                 sandbox_backend: "bwrap"
               })

      # The row `rename_space/2` returns is the row `Repo.update/1` persisted, so
      # the re-read is the immutability claim itself: the edit named another
      # backend and the space is still on the one it was created with.
      assert Spaces.get_space(space.id).sandbox_backend == "none"
    end
  end

  describe "sandbox_backend/1" do
    test "resolves a missing row to the default rather than raising" do
      assert Spaces.sandbox_backend(-1) == Backend.default()
    end
  end

  describe "none_space_ids/0" do
    test "lists exactly the none-backend spaces" do
      {:ok, none_space} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("sb-ids-none"),
          sandbox_backend: "none"
        })

      {:ok, bwrap_space} =
        Spaces.create_space(nil, %{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          name: unique("sb-ids-bwrap")
        })

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

    test "names the path when the scratch path is already something else" do
      # The name is free but the host directory is not Nest's, so the answer is
      # another name — and the client needs the path to say which one it means.
      assert {:error, %{"reason" => "scratch_path_taken", "path" => "/tmp/X11-unix"}} =
               AgentErrors.create_payload({:scratch_path_taken, "/tmp/X11-unix"})
    end
  end
end
