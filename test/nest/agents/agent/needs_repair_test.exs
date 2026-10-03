defmodule Nest.Agents.Agent.NeedsRepairTest do
  @moduledoc """
  On-load sequence classification (spec §4).

  A lone trailing assistant `tool_use` with no result is an interrupted
  turn, not corruption: the agent heals it (answers with an error result)
  and comes up `:idle`. Any other wire violation is real corruption and
  starts the agent in `:needs_repair` (history viewable, chat blocked)
  until an offline `mix nest.repair_messages` run plus a reload.
  """

  use Nest.DataCase, async: true

  alias Nest.Agents
  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Persistence.MessageRepair

  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()
    %{space_id: space_id}
  end

  describe "build_attrs_for_start/2" do
    test "classifies a lone trailing tool_use as an interrupted call, not a violation" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("interrupted")
      insert_interrupted_agent(space_id, name)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert attrs.sequence_violations == []
      assert attrs.repair_command == nil
      assert [%Part.ToolUse{id: "call_1", name: "shell-cmd"}] = attrs.interrupted_tool_call
    end

    test "attaches violations and a repair command for real corruption" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("corrupt")
      insert_corrupt_agent(space_id, name)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)

      assert [{:tool_pairing, _position}] =
               Enum.map(attrs.sequence_violations, &{&1.rule, &1.position})

      assert attrs.interrupted_tool_call == nil
      assert attrs.repair_command =~ "mix nest.repair_messages --space "
    end

    test "attaches nothing for a healthy sequence" do
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
      assert attrs.interrupted_tool_call == nil
      assert attrs.repair_command == nil
    end
  end

  describe "interrupted-tool-call recovery" do
    test "heal/2 answers a lone trailing tool_use with an error result and persists it" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("healed")
      insert_interrupted_agent(space_id, name)

      state =
        %Agent{
          name: name,
          space_id: space_id,
          llm_metrics: %Agent.LlmMetrics{
            context_limit: 100_000,
            context_limit_source: :config
          },
          chat_state: %Agent.ChatState{
            messages: [
              system(0),
              user(1, "run the command"),
              assistant_tool(2, "call_1")
            ],
            next_message_index: 3
          }
        }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          healed =
            Init.InterruptedToolCall.heal(state, [
              %Part.ToolUse{id: "call_1", name: "shell-cmd", arguments: %{}}
            ])

          assert [
                   {:tool,
                    %Tool{
                      parts: [%Part.ToolResult{tool_call_id: "call_1", is_error: true}]
                    }},
                   {:assistant, %Assistant{}}
                 ] = Enum.take(healed.chat_state.messages, -2)
        end)

      assert log =~ "interrupted tool call"

      # Persisted, so a subsequent load has nothing left to recover.
      assert [:system, :user, :assistant, :tool, :assistant] =
               Persistence.load_messages(space_id, name) |> Enum.map(&elem(&1, 0))

      assert {:ok, again} = Persistence.build_attrs_for_start(space_id, name)
      assert again.sequence_violations == []
      assert again.interrupted_tool_call == nil
    end

    test "a genuinely corrupt sequence blocks as :needs_repair and reloads to :idle after repair" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("blocked")
      insert_corrupt_agent(space_id, name)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert attrs.sequence_violations != []

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

  defp insert_interrupted_agent(space_id, name) do
    {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))

    insert_messages(space_id, name, [
      system(0),
      user(1, "run the command"),
      assistant_tool(2, "call_1")
    ])
  end

  # A tool_use answered by a following user turn is a mid-list pairing
  # violation, not a lone trailing orphan — real corruption.
  defp insert_corrupt_agent(space_id, name) do
    {:ok, _} = Persistence.insert_agent(agent_attrs(space_id, name))

    insert_messages(space_id, name, [
      system(0),
      user(1, "run the command"),
      assistant_tool(2, "call_1"),
      user(3, "still there?")
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
