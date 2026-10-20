defmodule Nest.Spaces.EnvironmentTest do
  @moduledoc """
  `Spaces.update_environment/2` — the one edit for a space's environment, and the
  three properties it owns: the workspace, the network access and the sandbox
  backend.

  Two things are easy to get wrong here and are pinned:

    * the **workspace** and the **backend** are editable too, not only the
      network (`test/nest/spaces/network_access_test.exs` is the network's own
      file, and every edit there names only that field);
    * the sandbox release is given the backend the row had **before** the write.
      A `"docker"` space's containers are the old backend's, so releasing the new
      one's would leak them — and the staging directory that backend leaves on the
      host is the observable that tells the two apart without a daemon
      (`config/test.exs` installs an inert runner, so the containers themselves
      are not observable here; `Nest.Sandbox.Backend.DockerTest` owns that).

  The workspace refusals are pinned where they are produced rather than here: the
  edit path's two codes are `NestWeb.LobbyChannelEditSpaceTest`'s (through a real
  `edit_space` push, which is the same `update_environment/2`), and the tagged
  `{:config_file_not_regular, path, type}` — with the path, so the user knows
  which file to replace — is `Nest.SandboxTest`'s, at `workspace_error/1` itself.

  The agent side — the notice a live agent gets, and the flag a stopped one keeps
  — is `Nest.Agents.Agent.WorkspaceTest`'s.
  """

  use Nest.DataCase, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.SpaceGate
  alias Nest.Sandbox.Paths
  alias Nest.Spaces
  alias Nest.Spaces.Space

  describe "update_environment/2" do
    test "moves the workspace" do
      {:ok, space} = space(%{workspace_path: AgentTestHelpers.default_test_workspace()})
      moved = tmp_workspace("env-workspace")

      assert {:ok, %Space{workspace_path: ^moved}} =
               Spaces.update_environment(space.id, %{workspace_path: moved})

      assert Spaces.get_space(space.id).workspace_path == moved
    end

    test "changes the sandbox backend" do
      {:ok, space} =
        space(%{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          sandbox_backend: "bwrap"
        })

      assert {:ok, %Space{sandbox_backend: "none"}} =
               Spaces.update_environment(space.id, %{sandbox_backend: "none"})

      assert Spaces.sandbox_backend(space.id) == "none"
    end

    test "refuses a backend this build does not implement" do
      # A row can name a backend this build does not have — `sandbox/backend.ex`
      # says so: it is what a rollback leaves behind. The refusal has to come
      # *before* the latch and the quiesce, or every save on such a space cancels
      # the whole space's work and then refuses. The observable is the
      # `{:space_locked, _}` frame `SpaceGate.hold/3` broadcasts before it returns,
      # below: `held?/1` cannot tell the two apart, because the edit releases the
      # latch in an `after` and it reads `false` either way.
      {:ok, space} = space(%{workspace_path: AgentTestHelpers.default_test_workspace()})

      id = space.id
      Phoenix.PubSub.subscribe(Nest.PubSub, SpaceGate.topic(id))

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Spaces.update_environment(space.id, %{sandbox_backend: "firecracker"})

      assert Keyword.has_key?(errors, :sandbox_backend)
      assert Spaces.sandbox_backend(space.id) == "bwrap"

      # The latch was never taken, so nothing was cancelled and nothing was
      # stopped. The frame is broadcast inside `hold`, before it returns, and a
      # local broadcast is a synchronous `send` — so its absence is a fact rather
      # than a window that has not elapsed.
      refute_receive {:space_locked, ^id}, 0
    end

    test "releases the sandbox of the backend the row had, not the one it names" do
      # A docker space, with the staging directory that backend keeps on the host.
      {:ok, space} =
        space(%{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          sandbox_backend: "docker"
        })

      stage = Paths.docker_stage_dir(space.id)
      File.mkdir_p!(stage)
      on_exit(fn -> File.rm_rf(Paths.docker_stage_dir(space.id)) end)

      assert {:ok, %Space{sandbox_backend: "bwrap"}} =
               Spaces.update_environment(space.id, %{sandbox_backend: "bwrap"})

      # The *old* backend's release ran. Reading the backend after the write
      # would have asked bwrap to release it, which is a no-op, and this
      # directory would still be here.
      refute File.exists?(stage)
    end
  end

  defp space(attrs) do
    {:ok, space_id} =
      AgentTestHelpers.create_test_space(Map.put_new(attrs, :name, unique("env-space")))

    {:ok, Spaces.get_space(space_id)}
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp tmp_workspace(label) do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_#{label}_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> rm_tmp!(dir, "nest_#{label}_") end)
    dir
  end
end
