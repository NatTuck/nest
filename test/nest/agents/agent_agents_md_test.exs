defmodule Nest.Agents.AgentAgentsMdTest do
  @moduledoc """
  Tests for AGENTS.md loading into the system prompt.
  """
  use Nest.DataCase, async: false

  import Mimic

  alias Nest.Agents.Agent.Config, as: AgentConfig
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  defp create_vocation do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "TestAgentsMd-#{Elixir.System.unique_integer([:positive])}",
        description: "Test",
        system_prompt: "Test system prompt",
        tools: []
      })

    vocation
  end

  describe "system_prompt with AGENTS.md" do
    test "includes AGENTS.md content when file exists in workspace" do
      vocation = create_vocation()
      workspace_path = File.cwd!()

      MockClient.set_response("OK")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          workspace_path: workspace_path,
          vocation_id: vocation.id
        })

      system_prompt = get_system_prompt(pid)
      assert is_binary(system_prompt)
      assert system_prompt =~ "Here are AGENTS.md guidelines for this project:"
      assert system_prompt =~ "This is a web application"

      MockClient.clear()
    end

    test "omits AGENTS.md section when workspace has no such file" do
      vocation = create_vocation()
      workspace_path = Path.join([File.cwd!(), "test", "data", "empty_workspace"])
      File.mkdir_p!(workspace_path)

      on_exit(fn -> File.rm_rf(workspace_path) end)

      MockClient.set_response("OK")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          workspace_path: workspace_path,
          vocation_id: vocation.id
        })

      system_prompt = get_system_prompt(pid)
      assert is_binary(system_prompt)
      refute system_prompt =~ "Here are AGENTS.md guidelines for this project:"

      MockClient.clear()
    end

    test "omits AGENTS.md section when workspace_path is nil" do
      vocation = create_vocation()

      MockClient.set_response("OK")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          workspace_path: nil,
          vocation_id: vocation.id
        })

      system_prompt = get_system_prompt(pid)
      assert is_binary(system_prompt)
      refute system_prompt =~ "Here are AGENTS.md guidelines for this project:"

      MockClient.clear()
    end

    test "AGENTS.md changes between init and compaction are reflected in the regenerated system prompt" do
      # Mutate AGENTS.md on disk between init and the
      # compaction regeneration. The new prompt at position 0
      # must reflect the latest file content.
      workspace =
        Path.join(
          Elixir.System.tmp_dir!(),
          "agents-md-#{Elixir.System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "FIRST version")
      on_exit(fn -> File.rm_rf!(workspace) end)

      vocation = create_vocation()
      MockClient.set_response("OK")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          workspace_path: workspace,
          vocation_id: vocation.id
        })

      # Mutate AGENTS.md after init.
      File.write!(Path.join(workspace, "AGENTS.md"), "SECOND version")

      summary_text = "..."

      iter = 0
      max = AgentConfig.configured_max_tool_iterations()

      tool_call_msg =
        {:assistant,
         %Assistant{
           index: 1,
           parts: [
             %Part.ToolUse{
               id: "call_1",
               name: "context",
               arguments: %{"action" => "compact"}
             }
           ],
           api_logs: []
         }}

      tool_result_msg =
        {:tool,
         %Tool{
           index: nil,
           timestamp: DateTime.utc_now(),
           parts: [
             %Part.ToolResult{
               tool_call_id: "call_1",
               name: "context",
               arguments: %{"action" => "compact"},
               content: "Compacted from N token previous context.",
               is_error: false
             }
           ],
           api_logs: []
         }}

      # Pre-seed `state.chat_state.messages` to end with the
      # assistant+ToolUse for `context.compact`. The new
      # `:compact_tool` continuation carries the pair inline; the
      # pre-seeded copy lands in `state.chat_state.history` after
      # the swap.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | messages: state.chat_state.messages ++ [tool_call_msg]
            }
        }
      end)

      send(
        pid,
        {:compaction_done, summary_text,
         {:compact_tool, [tool_call_msg, tool_result_msg], iter, max}}
      )

      # The new path spawns a ChatTurn; wait for the handler to
      # finish via `:sys.get_state/2` rather than receiving a
      # `:task_compaction_done` reply (the legacy path's tool
      # worker reply is gone in the unified design).
      _ = :sys.get_state(pid, 500)

      system_prompt = get_system_prompt(pid)
      assert is_binary(system_prompt)
      assert system_prompt =~ "SECOND version"
      refute system_prompt =~ "FIRST version"

      MockClient.clear()
    end
  end
end
