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
  alias Nest.Agents.Agent.Machine

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
      assert [%Part.ToolUse{id: "call_1", name: "shell-cmd"}] = attrs.load_heal
    end

    test "attaches violations and a repair command for real corruption" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("corrupt")
      insert_corrupt_agent(space_id, name)

      assert {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)

      assert [{:tool_pairing, _position}] =
               Enum.map(attrs.sequence_violations, &{&1.rule, &1.position})

      assert attrs.load_heal == nil
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
      assert attrs.load_heal == nil
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
            Init.LoadHeal.heal(state, [
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
      assert again.load_heal == nil
    end

    test "fetch_or_start_agent heals the orphan in the caller before the child spawns" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("orphan-load")
      insert_interrupted_agent(space_id, name)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, ^name} = Supervisor.fetch_or_start_agent(space_id, %{name: name})
        end)

      assert log =~ "interrupted tool call"

      # Healed and persisted in the caller's DB context — the spawned
      # child's `init/1` never touched the DB, which is what lets this
      # file run `async: true`.
      assert [:system, :user, :assistant, :tool, :assistant] =
               Persistence.load_messages(space_id, name) |> Enum.map(&elem(&1, 0))

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.status == :idle

      assert {:ok, again} = Persistence.build_attrs_for_start(space_id, name)
      assert again.sequence_violations == []
      assert again.load_heal == nil
    end

    test "a second heal of the interrupted tail appends nothing" do
      space_id = AgentTestHelpers.current_space_id()
      name = unique_name("heal-once")
      insert_interrupted_agent(space_id, name)

      {:ok, attrs} = Persistence.build_attrs_for_start(space_id, name)
      assert [%Part.ToolUse{id: "call_1"}] = attrs.load_heal

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")

      log = ExUnit.CaptureLog.capture_log(fn -> Agent.pre_load_heal(attrs) end)
      assert log =~ "interrupted tool call"

      # The error result and its ack were appended once, in order.
      assert_received {:chat_message,
                       {:tool,
                        %Tool{parts: [%Part.ToolResult{tool_call_id: "call_1", is_error: true}]}}}

      assert_received {:chat_message, {:assistant, %Assistant{index: 4}}}
      assert persisted_sequence(space_id, name) == healed_orphan_sequence()

      # A second caller holding the same pre-heal attrs re-derives the
      # classification from a fresh read, sees the healed tail, and appends
      # nothing: no second `tool_result`/ack pair, no second broadcast.
      # `capture_log` is here only so a regression's heal warning doesn't
      # print to the console.
      _ =
        ExUnit.CaptureLog.capture_log(fn ->
          again = Agent.pre_load_heal(attrs)
          assert again.load_heal == nil
          refute_received {:chat_message, _}
        end)

      assert persisted_sequence(space_id, name) == healed_orphan_sequence()
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

          assert Machine.status_for(state.live.machine) == :needs_repair
          assert state.live.repair.violations == attrs.sequence_violations
          assert state.live.repair.command == attrs.repair_command

          # The cast is dropped in `chat_or_queue/4`, so the active
          # message list is untouched.
          before = state.chat_state.messages
          _ref = Agent.chat(pid, "hello?")
          _ = :sys.get_state(pid)
          assert :sys.get_state(pid).chat_state.messages == before
        end)

      assert log =~ "invalid active message sequence"

      # The drop is logged too: `Agents.chat/4` is public and has non-channel
      # callers, whose message would otherwise vanish without trace.
      assert log =~ "dropping a chat message while status=:needs_repair"

      space_name = Nest.Spaces.get_space(space_id).name

      assert {:ok, _plan, _agents} =
               MessageRepair.run({:space, space_name}, apply: true)

      # The offline repair leaves the repaired sequence on a user tail, so
      # the reloaded agent's init heals it with the load bridge (appended
      # and persisted before the agent goes idle).
      reload_log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _name} = Agents.reload_agent(space_id, name)
        end)

      assert reload_log =~ "idle sequence ending on a user message"
      refute reload_log =~ "could not heal"

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.status == :idle

      # The bridge is persisted: the repaired user tail is closed by an
      # assistant ack, so a subsequent load has nothing left to heal.
      assert {:assistant, _} = Persistence.load_messages(space_id, name) |> List.last()

      assert {:ok, repaired} = Persistence.build_attrs_for_start(space_id, name)
      assert repaired.sequence_violations == []
      assert repaired.load_heal == nil
    end
  end

  # ---- helpers ----

  # The persisted sequence after the interrupted-tool-call heal: the error
  # result answers `call_1` and the ack closes the turn on an assistant.
  defp healed_orphan_sequence do
    [{0, :system}, {1, :user}, {2, :assistant}, {3, :tool}, {4, :assistant}]
  end

  # The persisted sequence as `{index, role}` pairs, so one assertion pins
  # the roles, their order, and that no extra row was appended.
  defp persisted_sequence(space_id, name) do
    Persistence.load_messages(space_id, name)
    |> Enum.map(fn {role, %{index: index}} -> {index, role} end)
  end

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
