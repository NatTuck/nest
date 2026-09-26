defmodule Nest.Agents.Agent.NeedsRepairTest do
  @moduledoc """
  On-load sequence validation (spec §4).

  An agent whose persisted *active* sequence fails wire preflight must
  start in the `:needs_repair` state (history still viewable, chat
  blocked), broadcast the repair banner, and recover to `:idle` after
  an offline `mix nest.repair_messages` run plus a reload.
  """

  use Nest.DataCase, async: true

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Persistence.MessageRepair

  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()
    %{space_id: space_id}
  end

  describe "build_attrs_for_start/2" do
    test "attaches the active-sequence violations and repair command" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("needs-repair")
      insert_invalid_agent(space_id, name)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert attrs.sequence_violations != []
      assert attrs.repair_command =~ "mix nest.repair_messages --space "
    end

    test "attaches no violations for a healthy sequence" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("healthy")
      {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))

      insert_messages(space_id, name, [
        system(0),
        user(1, "hi"),
        assistant_text(2)
      ])

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert attrs.sequence_violations == []
      assert attrs.repair_command == nil
    end
  end

  describe "Agent.init/1 with an invalid active sequence" do
    test "starts :needs_repair, drops chats, and reloads to :idle after a repair" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("blocked")
      insert_invalid_agent(space_id, name)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, pid} = Supervisor.start_under_test(attrs)
          state = :sys.get_state(pid)

          assert state.live.status == :needs_repair
          assert state.live.sequence_violations == attrs.sequence_violations
          assert state.live.repair_command == attrs.repair_command

          # The cast is dropped in `chat_or_drop/3`, so the active
          # message list is untouched.
          before = state.chat_state.messages
          _ref = Agent.chat(pid, "hello?")
          _ = :sys.get_state(pid)
          assert :sys.get_state(pid).chat_state.messages == before
        end)

      assert log =~ "invalid active message sequence"

      space_name = Nest.Spaces.get_space(space_id).name

      assert {:ok, _plan, _agents} =
               MessageRepair.run({:space, space_name}, apply: true)

      assert {:ok, _name} = Agents.reload_agent(space_id, name)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.status == :idle

      assert {:ok, repaired} = Persistence.build_attrs_for_start(space_id, name)
      assert repaired.sequence_violations == []
    end
  end

  # ---- helpers ----

  defp insert_invalid_agent(space_id, name) do
    {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))

    insert_messages(space_id, name, [
      system(0),
      user(1, "run the command"),
      assistant_tool(2, "call_1")
    ])
  end

  defp insert_messages(space_id, name, messages) do
    for message <- messages do
      {:ok, _} = Persistence.insert_message(space_id, name, message)
    end
  end

  defp agent_attrs(space_id, name) do
    %{
      space_id: space_id,
      name: name,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      workspace_path: nil,
      vocation_id: AgentTestHelpers.programmer_vocation_id_for_test()
    }
  end

  defp system(index) do
    {:system, %MsgSystem{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user(index, text), do: {:user, %User{index: index, parts: [%Part.Text{text: text}]}}

  defp assistant_text(index) do
    {:assistant, %Assistant{index: index, parts: [%Part.Text{text: "ok"}], api_logs: []}}
  end

  defp assistant_tool(index, id) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [%Part.ToolUse{id: id, name: "shell-cmd", arguments: %{}}],
       api_logs: []
     }}
  end

  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
