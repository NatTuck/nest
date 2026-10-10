defmodule Nest.Agents.Agent.WorkspaceTest do
  @moduledoc """
  Tests for `Agents.edit_agent/4` and `Agents.change_workspace/3` —
  changing an agent's working directory at runtime.

  The workspace change rebuilds the tool closures (which capture
  `workspace_path`), leaves the persisted system prompt (index 0)
  untouched to preserve the LLM prefix cache, and appends a
  user/assistant notice pair (after a compaction preflight check).
  """

  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Repo

  setup :verify_on_exit!

  setup do
    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    on_exit(fn -> :ok end)
    :ok
  end

  defp persist_and_start!(attrs) do
    name = Map.fetch!(attrs, :name)
    space_id = AgentTestHelpers.current_space_id()
    attrs_with_vid = attrs |> Map.put(:space_id, space_id)

    {:ok, _row} = Persistence.insert_agent(attrs_with_vid)
    {:ok, ^name} = Supervisor.fetch_or_start_agent(space_id, attrs_with_vid)
    {:ok, pid} = Supervisor.get_agent(space_id, name)

    Sandbox.allow(Repo, self(), pid)
    AgentTestHelpers.ensure_cleanup(name)

    {pid, name}
  end

  defp workspace_agent! do
    {:ok, vocation} =
      Nest.Vocations.create_vocation(%{
        name: "WS Test (#{System.unique_integer([:positive])})",
        description: "writes to workspace",
        system_prompt: "workspace prompt",
        tools: ["file", "shell", "context"],
        modes: %{
          "build" => %{
            "description" => "writes workspace",
            "caps" => %{
              "net" => false,
              "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
            }
          }
        }
      })

    old_ws = new_ws("old")

    {pid, _name} =
      persist_and_start!(%{
        name: "ws-agent-#{System.unique_integer([:positive])}",
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        workspace_path: old_ws,
        vocation_id: vocation.id
      })

    {pid, vocation.id, old_ws}
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
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "Agents.edit_agent/4" do
    test "updates the workspace, rebuilds tools, and appends the notice pair" do
      {pid, _vid, _old} = workspace_agent!()
      new = new_ws("new")

      system_before = List.first(:sys.get_state(pid).chat_state.messages)

      :ok =
        Agents.edit_agent(
          AgentTestHelpers.current_space_id(),
          agent_name(pid),
          test_model(),
          new
        )

      state = :sys.get_state(pid)
      assert state.workspace_path == new

      # Tool closures rebuilt against the new path.
      assert Enum.any?(state.tools, &(&1.name == "file-read"))

      # The system message (index 0) is untouched.
      system_after = List.first(state.chat_state.messages)
      assert system_after == system_before

      # The notice pair is the new tail.
      tail = Enum.take(state.chat_state.messages, -2)
      assert [{:user, user}, {:assistant, assistant}] = tail

      assert Enum.any?(
               user.parts,
               &(&1.text == "[mode: notice]\nWorkspace changed to: #{new}")
             )

      assert Enum.any?(assistant.parts, &(&1.text == "Workspace directory change confirmed."))
    end

    test "requires a non-null workspace when the vocation needs one" do
      {pid, _vid, old} = workspace_agent!()

      assert {:error, :workspace_required} =
               Agents.edit_agent(
                 AgentTestHelpers.current_space_id(),
                 agent_name(pid),
                 test_model(),
                 nil
               )

      # The agent's workspace is unchanged.
      assert :sys.get_state(pid).workspace_path == old
    end

    test "rejects a missing workspace and an under-/tmp workspace" do
      {pid, _vid, old} = workspace_agent!()

      assert {:error, :workspace_missing} =
               Agents.edit_agent(
                 AgentTestHelpers.current_space_id(),
                 agent_name(pid),
                 test_model(),
                 Path.join(old, "missing")
               )

      assert {:error, :workspace_under_tmp} =
               Agents.edit_agent(
                 AgentTestHelpers.current_space_id(),
                 agent_name(pid),
                 test_model(),
                 "/tmp/under"
               )

      assert :sys.get_state(pid).workspace_path == old
    end

    test "refuses while the agent is busy" do
      {pid, _vid, _old} = workspace_agent!()
      new = new_ws("new")

      :sys.replace_state(pid, fn state ->
        %{
          state
          | live: %{
              state.live
              | machine: Machine.status_to_machine(state.live.machine, :streaming)
            }
        }
      end)

      assert {:error, :agent_busy} =
               Agents.edit_agent(
                 AgentTestHelpers.current_space_id(),
                 agent_name(pid),
                 test_model(),
                 new
               )

      # The `:streaming` status was fabricated for the refusal check
      # (there is no real turn). Restore idle so the teardown's
      # zero-in-flight-agents assertion holds.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | live: %{
              state.live
              | machine: Machine.status_to_machine(state.live.machine, :idle)
            }
        }
      end)
    end
  end

  describe "Agents.change_workspace/3" do
    test "updates the workspace and appends the notice pair" do
      {pid, _vid, _old} = workspace_agent!()
      new = new_ws("new")

      :ok =
        Agents.change_workspace(
          AgentTestHelpers.current_space_id(),
          agent_name(pid),
          new
        )

      state = :sys.get_state(pid)
      assert state.workspace_path == new
      assert {:assistant, %{parts: parts}} = List.last(state.chat_state.messages)
      assert Enum.any?(parts, &(&1.text == "Workspace directory change confirmed."))
    end

    test "rejects a missing or under-/tmp workspace, leaving the agent unchanged" do
      {pid, _vid, old} = workspace_agent!()
      space_id = AgentTestHelpers.current_space_id()

      assert {:error, :workspace_missing} =
               Agents.change_workspace(space_id, agent_name(pid), Path.join(old, "missing"))

      assert {:error, :workspace_under_tmp} =
               Agents.change_workspace(space_id, agent_name(pid), "/tmp/under")

      assert :sys.get_state(pid).workspace_path == old
    end

    test "reapplies the max-depth spawn exclusion when tools are rebuilt" do
      {:ok, vocation} =
        Nest.Vocations.create_vocation(%{
          name: "WS Spawn (#{System.unique_integer([:positive])})",
          description: "spawn tools",
          system_prompt: "spawn prompt",
          tools: ["agents", "file"],
          modes: %{
            "build" => %{
              "description" => "writes workspace",
              "caps" => %{
                "net" => false,
                "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
              }
            }
          }
        })

      first = new_ws("spawn-old")
      second = new_ws("spawn-new")
      third = new_ws("spawn-newer")

      {pid, _name} =
        persist_and_start!(%{
          name: "ws-spawn-#{System.unique_integer([:positive])}",
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          workspace_path: first,
          vocation_id: vocation.id
        })

      space_id = AgentTestHelpers.current_space_id()

      # Below max depth the spawn tools survive the rebuild.
      :ok = Agents.change_workspace(space_id, agent_name(pid), second)
      assert Enum.any?(:sys.get_state(pid).tools, &(&1.name == "agents-spawn"))

      # At max depth they are dropped, matching Init/compaction.
      max = Config.configured_max_depth()
      :sys.replace_state(pid, fn state -> %{state | depth: max} end)

      :ok = Agents.change_workspace(space_id, agent_name(pid), third)

      tools = :sys.get_state(pid).tools
      refute Enum.any?(tools, &(&1.name in ["agents-spawn", "agents-batch"]))
      assert Enum.any?(tools, &(&1.name == "file-read"))
    end
  end

  describe "Agents.create_agent/3 workspace validation" do
    test "rejects a missing or /tmp-rooted workspace before starting" do
      space_id = AgentTestHelpers.current_space_id()
      model = test_model()
      base = new_ws("create-base")

      assert {:error, :workspace_missing} =
               Agents.create_agent(space_id, model, workspace_path: Path.join(base, "missing"))

      assert {:error, :workspace_under_tmp} =
               Agents.create_agent(space_id, model, workspace_path: "/tmp/ws")
    end
  end

  defp agent_name(pid), do: :sys.get_state(pid).name

  defp test_model, do: %{name: "qwen3.5-plus", provider: "model-studio"}
end
