defmodule Nest.Agents.AgentAgentsMdTest do
  @moduledoc """
  Tests for AGENTS.md loading into the system prompt.
  """
  use Nest.DataCase, async: false

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
      # Regression for: system prompt was fixed at agent init
      # and never re-read. After compaction the LLM continued
      # with a stale AGENTS.md even after the user edited the
      # file on disk. Per AGENTS.md, the system message may
      # change at compaction (the prefix cache is invalidated
      # by the compaction itself) — so the compactor now
      # re-renders the prompt via `SystemPrompt.compose_vocation_config/4`,
      # which re-reads AGENTS.md from disk at
      # `Nest.Agents.Agent.SystemPrompt.agents_md_section/1`.
      #
      # The setup writes AGENTS.md content X, starts an agent
      # (system prompt contains X), then mutates the file to
      # content Y and triggers a compaction. The post-compaction
      # `state.chat_state.messages[0]` (system) must reflect Y.
      #
      # This test pins the on-disk re-read behavior in
      # isolation. Same logic also covers vocation re-reads —
      # see `agent_compaction_system_repeat_test.exs`.
      vocation = create_vocation()
      original_agents_md = Path.join(File.cwd!(), "AGENTS.md")

      backup_path =
        Path.join(System.tmp_dir!(), "agents_md_backup_#{System.unique_integer([:positive])}")

      File.cp!(original_agents_md, backup_path)

      on_exit(fn -> File.cp!(backup_path, original_agents_md) end)

      new_content =
        "# Secret agent directive\nFROM_COMPACTION_FIXTURE\nunique-marker-#{System.unique_integer([:positive])}\n"

      try do
        File.write!(original_agents_md, new_content)

        {pid, agent_id} =
          start_agent(%{
            model: %{name: "qwen3.5-plus"},
            workspace_path: File.cwd!(),
            vocation_id: vocation.id
          })

        Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

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
        assert text =~ "FROM_COMPACTION_FIXTURE"
      after
        File.cp!(backup_path, original_agents_md)
      end
    end
  end
end
