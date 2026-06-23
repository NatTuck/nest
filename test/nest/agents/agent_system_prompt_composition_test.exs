defmodule Nest.Agents.AgentSystemPromptCompositionTest do
  @moduledoc """
  Tests for the system-prompt composition in
  `Nest.Agents.Agent.ChatPipeline` (the workspace line, the
  mode catalog, the AGENTS.md section, etc.). Extracted from
  `agent_chat_test.exs` so the chat-flow file stays under the
  500-line credo limit.
  """
  use Nest.DataCase, async: false

  import Mimic

  alias Nest.LLM.MockClient
  alias Nest.Test.TaskDrain
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    on_exit(fn -> TaskDrain.drain() end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "vocation system_prompt composition" do
    @tag :db_shared
    test "vocation system_prompt gets the mode catalog and a [Workspace] section" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestSysPrompt-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Base prompt.",
          tools: [],
          modes: %{
            "build" => %{
              "description" => "You're clear to edit the project in the workspace.",
              "caps" => valid_caps
            }
          }
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id,
          workspace_path: "/tmp/test-workspace-#{System.unique_integer([:positive])}"
        })

      # The system prompt isn't on any broadcast; only the agent's
      # process state has it. Kept on the get_system_prompt GenServer
      # call. Future work: include it on the chat:status payload.
      system_prompt = get_system_prompt(pid)

      assert system_prompt =~ "Base prompt."
      assert system_prompt =~ "\n\n[Available modes]\n\n"
      assert system_prompt =~ ~s(- build: Read only "/")
      assert system_prompt =~ "Network disabled"
      assert system_prompt =~ "You're clear to edit the project in the workspace."
      assert system_prompt =~ "\n\nWorkspace and tool working directory: /tmp/test-workspace-"
    end

    @tag :db_shared
    test "no workspace line when workspace_path is nil" do
      valid_caps = %{
        "net" => false,
        "fs" => %{"read" => ["/"], "write" => []}
      }

      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "TestNoWorkspace-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Chat only.",
          tools: [],
          modes: %{
            "chat" => %{
              "description" => "General conversation.",
              "caps" => valid_caps
            }
          }
        })

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation.id
        })

      system_prompt = get_system_prompt(pid)

      assert system_prompt =~ "Chat only."
      refute system_prompt =~ "Workspace and tool working directory"
    end
  end
end
