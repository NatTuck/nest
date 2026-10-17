defmodule Nest.Agents.Agent.WorkspaceTest do
  @moduledoc """
  Tests for `WorkspaceHandler.apply_space_environment/2` — applying a change to
  the **space's** environment on a live agent — and for the workspace validation
  `Agents.create_agent/3` still performs.

  There is no per-agent workspace to edit: a workspace is
  `spaces.workspace_path`, so the agent edit dialog no longer carries one and
  `Agents.change_workspace/3` / `Agents.set_workspace/2` are gone. The function
  these tests drive has no caller yet — the space edit that will drive it is the
  next step — so what they pin is the seam it will use: the mounts move, the tool
  closures are rebuilt against them, the persisted system prompt (index 0) is
  untouched to preserve the LLM prefix cache, and the change is announced as a
  user/assistant notice pair naming the values now in force.
  """

  use Nest.DataCase, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Agents
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.WorkspaceHandler
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Sandbox.Mounts

  setup do
    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    on_exit(fn -> :ok end)
    :ok
  end

  describe "apply_space_environment/2" do
    test "moves the mounts, rebuilds the tools, and appends the notice pair" do
      old = new_ws("old")
      new = new_ws("new")

      # A vocation with the file tools, so the rebuild has a closure to rebuild.
      {:ok, vocation} =
        Nest.Vocations.create_vocation(%{
          name: "WS Test (#{System.unique_integer([:positive])})",
          description: "writes to workspace",
          system_prompt: "workspace prompt",
          tools: ["file", "shell", "context"]
        })

      {pid, _name} =
        AgentTestHelpers.start_agent(%{workspace_path: old, vocation_id: vocation.id})

      # allowlist: snapshot — the mounts, tools and messages the apply moves
      before = :sys.get_state(pid, 1_000)
      assert Mounts.workspace(before.mounts) == old
      system_before = List.first(before.chat_state.messages)

      {state, :ok} =
        WorkspaceHandler.apply_space_environment(before, %{
          workspace: new,
          network_access: false,
          backend: "none"
        })

      # All three space properties ride the mounts, and all three moved.
      assert Mounts.workspace(state.mounts) == new
      assert Mounts.network_access(state.mounts) == false
      assert Mounts.backend(state.mounts) == "none"

      # Tool closures rebuilt against the new mounts.
      assert Enum.any?(state.tools, &(&1.name == "file-read"))

      # The system message (index 0) is untouched: rebuilding it would break the
      # prefix cache.
      assert List.first(state.chat_state.messages) == system_before

      # The notice pair is the new tail, and it states the values now in force
      # rather than a delta — a reconciliation, so two edits cannot leave the
      # agent holding a partial picture.
      assert [{:user, user}, {:assistant, assistant}] = Enum.take(state.chat_state.messages, -2)

      text = Enum.map_join(user.parts, "", &(&1.text || ""))

      assert text =~ "[nest notice]"
      assert text =~ "Workspace: #{new}"
      assert text =~ "Network access: disabled"
      assert text =~ "Sandbox: none"

      assert Enum.any?(assistant.parts, &(&1.text == "Space environment change confirmed."))
    end

    test "reapplies the max-depth spawn exclusion when tools are rebuilt" do
      {:ok, vocation} =
        Nest.Vocations.create_vocation(%{
          name: "WS Spawn (#{System.unique_integer([:positive])})",
          description: "spawn tools",
          system_prompt: "spawn prompt",
          tools: ["agents", "file"]
        })

      first = new_ws("spawn-old")
      second = new_ws("spawn-new")

      {pid, _name} =
        AgentTestHelpers.start_agent(%{workspace_path: first, vocation_id: vocation.id})

      # allowlist: snapshot — the tools the apply rebuilds
      before = :sys.get_state(pid, 1_000)
      assert Enum.any?(before.tools, &(&1.name == "agents-spawn"))

      # Below max depth the spawn tools survive the rebuild.
      {below, :ok} = apply_workspace(before, second)
      assert Enum.any?(below.tools, &(&1.name == "agents-spawn"))

      # At max depth they are dropped, matching `Init` and compaction.
      at_max = %{before | depth: Config.configured_max_depth()}
      {dropped, :ok} = apply_workspace(at_max, second)

      refute Enum.any?(dropped.tools, &(&1.name in ["agents-spawn", "agents-batch"]))
      assert Enum.any?(dropped.tools, &(&1.name == "file-read"))
    end
  end

  describe "Agents.create_agent/3 workspace validation" do
    test "rejects a space whose workspace is missing or /tmp-rooted" do
      # The workspace is the space's, so this is where the value is validated on
      # the way into an agent — `spaces.workspace_path` is checked by
      # `Spaces.ensure_root_workspace/2` when the space is created, and an agent
      # start re-checks it because a space row can be backfilled with a path the
      # sandbox cannot bind.
      base = new_ws("create-base")
      model = %{name: "qwen3.5-plus", provider: "model-studio"}

      {:ok, missing_space} =
        AgentTestHelpers.create_test_space(%{workspace_path: Path.join(base, "missing")})

      assert {:error, :workspace_missing} = Agents.create_agent(missing_space, model)

      {:ok, tmp_space} = AgentTestHelpers.create_test_space(%{workspace_path: "/tmp/ws"})
      assert {:error, :workspace_under_tmp} = Agents.create_agent(tmp_space, model)
    end
  end

  defp apply_workspace(state, path) do
    WorkspaceHandler.apply_space_environment(state, %{
      workspace: path,
      network_access: Mounts.network_access(state.mounts),
      backend: Mounts.backend(state.mounts)
    })
  end

  # A real workspace directory outside /tmp: the scratch dir is bound at /tmp,
  # so a /tmp-rooted workspace is rejected, and a non-existent one too.
  defp new_ws(label) do
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_ws_#{label}_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> rm_tmp!(dir, "nest_ws_") end)
    dir
  end
end
