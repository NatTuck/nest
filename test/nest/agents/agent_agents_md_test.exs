defmodule Nest.Agents.AgentAgentsMdTest do
  @moduledoc """
  Tests for AGENTS.md loading into the system prompt.
  """
  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
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
      # `test/data/agents_md_workspace/AGENTS.md` is a committed
      # fixture (small, reviewed in PR) so this test doesn't
      # depend on the project's `AGENTS.md` — which other tests
      # mutate and back up — and doesn't need to be re-baselined
      # when the project `AGENTS.md` drifts. Mirrors the
      # `test/data/empty_workspace/` pattern used by the test
      # below.
      vocation = create_vocation()
      workspace_path = Path.join([File.cwd!(), "test", "data", "agents_md_workspace"])

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
      vocation = create_vocation()

      workspace_path =
        Path.join(
          System.tmp_dir!(),
          "nest-tmp-agents-md-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(workspace_path)
      on_exit(fn -> safe_rm_rf(workspace_path) end)

      agents_md_path = Path.join(workspace_path, "AGENTS.md")

      marker = "unique-marker-#{System.unique_integer([:positive])}"

      File.write!(
        agents_md_path,
        "# Secret agent directive\nFROM_COMPACTION_FIXTURE\n#{marker}\n"
      )

      {pid, agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          workspace_path: workspace_path,
          vocation_id: vocation.id
        })

      # Pre-seed messages and trigger compaction.
      messages = [
        {:system,
         %Nest.Messages.System{index: 0, parts: [%Part.Text{text: "Original"}], api_logs: []}},
        {:user, %Nest.Messages.User{index: 1, parts: [%Part.Text{text: "hi"}], api_logs: []}}
      ]

      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | messages: messages}}
      end)

      send(pid, {:compaction_done, "Summary text.", nil})
      _ = :sys.get_state(pid)

      final_messages = :sys.get_state(pid).chat_state.messages

      assert match?({:system, _}, Enum.at(final_messages, 0)),
             "expected system message at messages[0]"

      [{:system, sys_struct}] = Enum.take(final_messages, 1)
      text = AgentTestHelpers.text_from_parts(sys_struct.parts)
      assert text =~ marker
    end
  end

  defp safe_rm_rf(path) do
    if String.contains?(path, "nest-tmp") do
      File.rm_rf!(path)
    end
  end
end
