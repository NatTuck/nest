defmodule Nest.Agents.Agent.NoticePairInjectorTest do
  @moduledoc """
  Tests for `NoticePairInjector` — the wire-safe synthetic
  notice pair injection that the Case 2 (LLM-response) and Case C
  (user-message) paths both delegate to.

  Coverage:
    * `inject_pair/3` and `inject_pair_in_process/4` agree on shape
      for the same trailing role.
    * Atomicity: the pair either lands fully or doesn't land at all
      — no half-pair is ever observable in the messages list.
    * Wire-safety: the chosen shape preserves the user/assistant
      alternation that Anthropic and OpenAI require.
  """

  use Nest.DataCase, async: true
  use Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.NoticePairInjector
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()
    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    :ok
  end

  describe "inject_pair/3 — cross-process (GenServer.call path)" do
    test "the agent's :append_messages handler appends both halves with sequential indices" do
      {pid, _agent_id} = start_agent_test_helper()

      NoticePairInjector.inject_pair(
        pid,
        %{
          kind: :budget,
          attention: "Tool limit?",
          notice: "Last tool call round. Provide your final response after this tool."
        },
        :agent_user
      )

      state = :sys.get_state(pid)
      last_two = Enum.take(state.chat_state.messages, -2)
      [first, second] = last_two

      assert {:assistant, %Assistant{index: idx1}} = first
      assert idx1 == state.chat_state.next_message_index - 2

      assert {:user, %User{index: idx2}} = second
      assert idx2 == idx1 + 1
    end

    test "returns :agent_user_pair shape when both halves land" do
      {pid, _agent_id} = start_agent_test_helper()

      assert {:ok, :agent_user_pair, [_attn, _notice]} =
               NoticePairInjector.inject_pair(
                 pid,
                 %{kind: :budget, attention: "Tool limit?", notice: "x"},
                 :agent_user
               )
    end
  end

  describe "inject_pair_in_process/4 — in-process (no GenServer.call)" do
    test "delegates to __append_messages__/2 with both halves" do
      {pid, _agent_id} = start_agent_test_helper()
      state0 = :sys.get_state(pid)

      {:ok, :agent_user_pair, _stamped, state1} =
        NoticePairInjector.inject_pair_in_process(
          state0.chat_state.messages,
          state0,
          %{kind: :budget, attention: "Tool limit?", notice: "x"},
          :agent_user
        )

      assert length(state1.chat_state.messages) == length(state0.chat_state.messages) + 2
      # Index advance matches the count of appended messages.
      assert state1.chat_state.next_message_index ==
               state0.chat_state.next_message_index + 2
    end

    test "returns :deferred when the trailing assistant carries an unpaired tool_use" do
      messages = [
        {:assistant,
         %Assistant{
           index: 0,
           parts: [%Nest.Messages.Part.ToolUse{id: "call_1", name: "shell_cmd", arguments: %{}}],
           timestamp: nil,
           api_logs: []
         }}
      ]

      state = build_state(messages)

      assert :deferred ==
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 state,
                 %{kind: :budget, attention: "Tool limit?", notice: "x"},
                 :agent_user
               )
    end

    test "returns :deferred when the trailing assistant carries an unpaired tool_use even on the :user_agent direction" do
      messages = [
        {:assistant,
         %Assistant{
           index: 0,
           parts: [%Nest.Messages.Part.ToolUse{id: "call_1", name: "shell_cmd", arguments: %{}}],
           timestamp: nil,
           api_logs: []
         }}
      ]

      state = build_state(messages)

      assert :deferred ==
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 state,
                 %{kind: :context, attention: "Context?", notice: "x"},
                 :user_agent
               )
    end
  end

  describe "shape selection" do
    test ":agent_user with trailing :tool builds :agent_user_pair" do
      messages = [{:tool, %Tool{index: 0, parts: [], timestamp: nil, api_logs: []}}]
      state = build_state(messages)

      assert {:ok, :agent_user_pair, _stamped, _state} =
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 state,
                 %{kind: :budget, attention: "Tool limit?", notice: "x"},
                 :agent_user
               )
    end

    test ":user_agent with trailing :user builds :single_assistant" do
      messages = [
        {:user, %User{index: 0, parts: [], timestamp: nil, api_logs: [], metadata: %{}}}
      ]

      state = build_state(messages)

      assert {:ok, :single_assistant, _stamped, _state} =
               NoticePairInjector.inject_pair_in_process(
                 messages,
                 state,
                 %{kind: :context, attention: "Context?", notice: "x"},
                 :user_agent
               )
    end

    test ":user_agent with trailing :tool builds :single_assistant" do
      # Trailing :tool is wire-equivalent to :user (Anthropic sends
      # tool results as user-role messages, per
      # `MessageList.last_wire_role/1`). The new user message that
      # will follow means the wire sequence is `tool → assistant →
      # user` — a single `[assistant(notice+ack)]` suffices; a
      # full `[user(notice), assistant(ack)]` pair would create
      # wire `tool(as user) → user(notice) → assistant(ack) →
      # user(real)` — INVALID back-to-back users.
      messages = [{:tool, %Tool{index: 0, parts: [], timestamp: nil, api_logs: []}}]
      state = build_state(messages)

      result =
        NoticePairInjector.inject_pair_in_process(
          messages,
          state,
          %{kind: :context, attention: "Context?", notice: "x"},
          :user_agent
        )

      assert {:ok, :single_assistant, _stamped, _state} = result
    end

    test ":user_agent with trailing :assistant (no tool_use) builds :user_agent_pair" do
      # Trailing assistant (no trailing tool_use): the new user
      # message that will follow means the wire sequence is
      # `assistant → user(notice) → assistant(ack) → user(real)` —
      # strict alternation. The full pair is required.
      messages = [
        {:assistant,
         %Assistant{
           index: 0,
           parts: [%Nest.Messages.Part.Text{text: "ok"}],
           timestamp: nil,
           api_logs: []
         }}
      ]

      state = build_state(messages)

      result =
        NoticePairInjector.inject_pair_in_process(
          messages,
          state,
          %{kind: :context, attention: "Context?", notice: "x"},
          :user_agent
        )

      assert {:ok, :user_agent_pair, _stamped, _state} = result
    end
  end

  # --- helpers ---

  # Start an agent and return the pid. The cross-process tests
  # need a real GenServer target for `GenServer.call`.
  defp start_agent_test_helper do
    {pid, agent_id} = AgentTestHelpers.start_agent(%{model: %{name: "qwen3.5-plus"}})
    {pid, agent_id}
  end

  # Build a minimal Agent state for the in-process tests.
  defp build_state(messages) do
    %Agent{
      chat_state: %Agent.ChatState{
        messages: messages,
        next_message_index: next_index(messages)
      }
    }
  end

  defp next_index(messages) do
    case Enum.map(messages, fn {_, %{index: i}} -> i end) |> Enum.max() do
      nil -> 0
      max -> max + 1
    end
  end
end
