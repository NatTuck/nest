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

  import Mimic

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
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
        tools: ["file-read", "file-write", "shell-cmd", "context-check", "context-compact"],
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

    {pid, _name} =
      persist_and_start!(%{
        name: "ws-agent-#{System.unique_integer([:positive])}",
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        workspace_path: "/old/workspace",
        vocation_id: vocation.id
      })

    {pid, vocation.id}
  end

  describe "Agents.edit_agent/4" do
    test "updates the workspace, rebuilds tools, and appends the notice pair" do
      {pid, _vid} = workspace_agent!()

      system_before = List.first(:sys.get_state(pid).chat_state.messages)

      :ok =
        Agents.edit_agent(
          AgentTestHelpers.current_space_id(),
          agent_name(pid),
          test_model(),
          "/new/workspace"
        )

      state = :sys.get_state(pid)
      assert state.workspace_path == "/new/workspace"

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
               &(&1.text == "[mode: notice]\nWorkspace changed to: /new/workspace")
             )

      assert Enum.any?(assistant.parts, &(&1.text == "Workspace directory change confirmed."))
    end

    test "requires a non-null workspace when the vocation needs one" do
      {pid, _vid} = workspace_agent!()

      assert {:error, :workspace_required} =
               Agents.edit_agent(
                 AgentTestHelpers.current_space_id(),
                 agent_name(pid),
                 test_model(),
                 nil
               )

      # The agent's workspace is unchanged.
      assert :sys.get_state(pid).workspace_path == "/old/workspace"
    end

    test "refuses while the agent is busy" do
      {pid, _vid} = workspace_agent!()
      :sys.replace_state(pid, fn state -> %{state | live: %{state.live | status: :streaming}} end)

      assert {:error, :agent_busy} =
               Agents.edit_agent(
                 AgentTestHelpers.current_space_id(),
                 agent_name(pid),
                 test_model(),
                 "/new/workspace"
               )
    end
  end

  describe "Agents.change_workspace/3" do
    test "updates the workspace and appends the notice pair" do
      {pid, _vid} = workspace_agent!()

      :ok =
        Agents.change_workspace(
          AgentTestHelpers.current_space_id(),
          agent_name(pid),
          "/new/workspace"
        )

      state = :sys.get_state(pid)
      assert state.workspace_path == "/new/workspace"
      assert {:assistant, %{parts: parts}} = List.last(state.chat_state.messages)
      assert Enum.any?(parts, &(&1.text == "Workspace directory change confirmed."))
    end
  end

  defp agent_name(pid), do: :sys.get_state(pid).name

  defp test_model, do: %{name: "qwen3.5-plus", provider: "model-studio"}
end
