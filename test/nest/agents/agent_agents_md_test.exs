defmodule Nest.Agents.AgentAgentsMdTest do
  @moduledoc """
  Tests for AGENTS.md loading into the system prompt.
  """
  use Nest.DataCase, async: true

  import Mimic

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Sandbox.Mounts
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
      # when the project `AGENTS.md` drifts.
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

    test "sanitizes NUL and invalid UTF-8 in AGENTS.md" do
      vocation = create_vocation()

      workspace_path =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "nest-tmp-agents-md-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(workspace_path)
      on_exit(fn -> rm_tmp!(workspace_path, "nest-tmp-agents-md-") end)

      File.write!(
        Path.join(workspace_path, "AGENTS.md"),
        "before" <> <<0>> <> "middle" <> <<0xFF>> <> "after"
      )

      MockClient.set_response("OK")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          workspace_path: workspace_path,
          vocation_id: vocation.id
        })

      system_prompt = get_system_prompt(pid)
      assert is_binary(system_prompt)
      assert String.valid?(system_prompt)
      refute String.contains?(system_prompt, <<0>>)

      replacement = <<0xEF, 0xBF, 0xBD>>
      assert system_prompt =~ "before" <> replacement <> "middle" <> replacement <> "after"

      MockClient.clear()
    end

    test "omits AGENTS.md section when workspace has no such file" do
      vocation = create_vocation()

      workspace_path =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "nest-tmp-agents-md-empty-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(workspace_path)

      on_exit(fn -> rm_tmp!(workspace_path, "nest-tmp-agents-md-") end)

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

    # There was a test here asserting the notice a symlinked `AGENTS.md` used to
    # get in the prompt. A *start* no longer renders one: `Nest.ConfigFile.error/1`
    # refuses the workspace on all three funnels, so no agent comes up in one. The
    # arm still exists because composition is re-run **mid-session** (on
    # compaction), which is what the `:hardlink`/symlink tests at the end of this
    # file drive directly.
    test "omits the AGENTS.md section when the mounts carry no workspace" do
      # An agent always has its *space's* workspace now, so this state is only
      # reachable through the composer — which is where the clause lives. A
      # `nil` workspace must not attempt a sandbox read at all.
      vocation = create_vocation()

      {system_prompt, _tools, _vocation} =
        SystemPrompt.compose_vocation_config(
          vocation,
          Mounts.new(nil, nil),
          {nil, nil},
          "agent",
          0,
          nil
        )

      assert is_binary(system_prompt)
      refute system_prompt =~ "Here are AGENTS.md guidelines for this project:"
    end

    test "AGENTS.md changes between init and compaction are reflected in the regenerated system prompt" do
      vocation = create_vocation()

      workspace_path =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "nest-tmp-agents-md-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(workspace_path)
      on_exit(fn -> rm_tmp!(workspace_path, "nest-tmp-agents-md-") end)

      agents_md_path = Path.join(workspace_path, "AGENTS.md")

      marker = "unique-marker-#{System.unique_integer([:positive])}"

      File.write!(
        agents_md_path,
        "# Secret agent directive\nFROM_COMPACTION_FIXTURE\n#{marker}\n"
      )

      {pid, _agent_id} =
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

      :sys.replace_state(
        pid,
        fn state ->
          %{state | chat_state: %{state.chat_state | messages: messages}}
        end,
        1_000
      )

      send_compaction_done(pid, "Summary text.", nil)

      # The commit broadcasts `chat:compaction` inline from the agent while it
      # handles the response, after the marker and the regenerated messages are
      # in the state — so the frame is the happens-after event for the commit,
      # and the read below (a call to the same process) is ordered behind it.
      # The marker payload is the pin: a fence that could be satisfied by
      # anything other than a commit would fail here.
      assert_receive {:chat_compaction, %{marker: %{"role" => "compaction"}}}, 1_000

      final_messages = Nest.Agents.Agent.get_messages(pid, 1_000)

      assert match?({:system, _}, Enum.at(final_messages, 0)),
             "expected system message at messages[0]"

      [{:system, sys_struct}] = Enum.take(final_messages, 1)
      text = AgentTestHelpers.text_from_parts(sys_struct.parts)
      assert text =~ marker

      # The `nil` continuation resumes the post-compaction LLM turn;
      # finish it so the agent is idle when the test ends (the
      # teardown asserts zero in-flight agents).
      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end
  end

  # `compose_vocation_config/6` is re-run **mid-session** (on compaction), so both
  # arms below are reachable while an agent is running — no agent can *start* in a
  # workspace the gate refuses, which is why the start-time tests cannot see them.
  describe "an AGENTS.md that is not a regular file" do
    test "renders a notice rather than silently dropping the project's policy" do
      vocation = create_vocation()
      ws = AgentTestHelpers.default_test_workspace()

      File.write!(Path.join(ws, "real.md"), "policy")
      File.ln_s!(Path.join(ws, "real.md"), Path.join(ws, "AGENTS.md"))

      prompt = compose(vocation, ws)

      assert prompt =~ "AGENTS.md is not a regular file"
      assert prompt =~ "Your tools will refuse to run in this workspace until it is replaced"
      assert prompt =~ "do not treat anything you find there as policy this session"
      # Not the silent drop it used to be: the section is replaced, not omitted.
      refute prompt =~ "Here are AGENTS.md guidelines"
    end
  end

  describe "an AGENTS.md with nothing in it" do
    test "adds no section at all" do
      # This is the *steady* state of a workspace without an `AGENTS.md`: the
      # `/dev/null` mask materialises an empty `0444` file on the first command, so
      # `{:ok, ""}` is what every later composition reads. A heading with no
      # guidelines under it claims more than there is.
      vocation = create_vocation()
      ws = AgentTestHelpers.default_test_workspace()
      path = Path.join(ws, "AGENTS.md")

      for content <- ["", "  \n\t\n"] do
        File.write!(path, content)

        refute compose(vocation, ws) =~ "Here are AGENTS.md guidelines"
      end
    end
  end

  defp compose(vocation, workspace) do
    {prompt, _tools, _vocation} =
      SystemPrompt.compose_vocation_config(
        vocation,
        Mounts.new(workspace, nil),
        {128_000, :default},
        "agent-under-test",
        0,
        nil
      )

    prompt
  end
end
