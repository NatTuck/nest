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

  The agent side — the notice a live agent gets, and the flag a stopped one keeps
  — is `Nest.Agents.Agent.WorkspaceTest`'s.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Nest.Test.TmpCleanup

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Persistence
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
      assert Spaces.workspace_path(space.id) == moved
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
      assert Spaces.get_space(space.id).workspace_path == space.workspace_path
    end

    test "refuses a backend this build does not implement" do
      {:ok, space} = space(%{workspace_path: AgentTestHelpers.default_test_workspace()})

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Spaces.update_environment(space.id, %{sandbox_backend: "firecracker"})

      assert Keyword.has_key?(errors, :sandbox_backend)
      assert Spaces.sandbox_backend(space.id) == "bwrap"
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

    test "a save that names what the row already says is not an edit" do
      {:ok, space} =
        space(%{
          workspace_path: AgentTestHelpers.default_test_workspace(),
          sandbox_backend: "docker"
        })

      stage = Paths.docker_stage_dir(space.id)
      File.mkdir_p!(stage)
      on_exit(fn -> File.rm_rf(Paths.docker_stage_dir(space.id)) end)

      {:ok, agent_name} = live_agent(space.id)

      assert {:ok, %Space{}} =
               Spaces.update_environment(space.id, %{
                 workspace_path: space.workspace_path,
                 network_access: space.network_access,
                 sandbox_backend: space.sandbox_backend
               })

      # Nothing moved, so nothing was released...
      assert File.exists?(stage)
      # ...and nobody was told: the flag stays clear, so no agent announces a
      # change that did not happen.
      assert pending?(space.id, agent_name) == false
    end

    test "refuses a workspace whose config file Nest cannot protect" do
      # A `.nest` or `AGENTS.md` that is not a regular file cannot be masked into
      # the sandbox, so the workspace is refused — and the reason is *tagged*, with
      # the path, because the user has to know which file to replace. The same
      # code the create path produces for the same workspace.
      {:ok, space} = space(%{workspace_path: AgentTestHelpers.default_test_workspace()})
      moved = tmp_workspace("env-config-file")
      path = Path.join(moved, ".nest")
      File.write!(Path.join(moved, "real.nest"), "")
      File.ln_s!(Path.join(moved, "real.nest"), path)

      # The refusal is logged (it names the file); capture it and assert on it.
      log =
        capture_log(fn ->
          assert {:error, {:config_file_not_regular, ^path, :symlink}} =
                   Spaces.update_environment(space.id, %{workspace_path: moved})
        end)

      assert log =~ "cannot protect it from being rewritten"

      assert Spaces.get_space(space.id).workspace_path == space.workspace_path
    end

    test "refuses a workspace the sandbox cannot run" do
      {:ok, space} = space(%{workspace_path: AgentTestHelpers.default_test_workspace()})

      assert {:error, :workspace_under_tmp} =
               Spaces.update_environment(space.id, %{workspace_path: "/tmp/not-a-workspace"})

      assert {:error, :workspace_missing} =
               Spaces.update_environment(space.id, %{workspace_path: "/nonexistent/nest-ws"})

      assert Spaces.get_space(space.id).workspace_path == space.workspace_path
    end
  end

  defp space(attrs) do
    {:ok, space_id} =
      AgentTestHelpers.create_test_space(Map.put_new(attrs, :name, unique("env-space")))

    {:ok, Spaces.get_space(space_id)}
  end

  # A live agent in `space_id`, so "nobody was told" has a subject. Started
  # through the caller interface so it is registered where the edit looks.
  defp live_agent(space_id) do
    name = unique("env-agent")

    {:ok, ^name} =
      Agents.create_agent(
        space_id,
        %{name: "qwen3.5-plus", provider: "model-studio"},
        name: name,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      )

    {:ok, pid} = Agents.Supervisor.get_agent(space_id, name)
    Sandbox.allow(Nest.Repo, self(), pid)
    AgentTestHelpers.ensure_cleanup(name)
    {:ok, name}
  end

  defp pending?(space_id, name) do
    {:ok, row} = Persistence.fetch_agent(space_id, name)
    row.space_notice_pending
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
