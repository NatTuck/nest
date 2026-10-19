defmodule Nest.Agents.Agent.TurnAcceptanceTest do
  @moduledoc """
  Acceptance tests for the Agent's in-process turn driver — the
  iteration state machine that drives each chat turn — and for the
  shape of the transcript it produces: one iteration
  (system, user, assistant), a tool iteration (tool call, tool
  result, final assistant), and two consecutive turns (strictly
  monotonic indices).

  The other transitions of the same machine are driven by
  `Nest.Agents.AgentSystemMessagesTest` (budget reminder),
  `Nest.Agents.AgentToolsMaxIterationsTest` (max-iterations second
  chance), `Nest.Agents.AgentStopTest` (user stop),
  `Nest.Agents.ChatTaskCrashTest` (HTTP worker crash) and
  `Nest.Agents.AgentObservabilityTest` (nil usage). They are not
  repeated here.

  The transcript is read from one atomic snapshot
  (`:sys.get_state/2`) only where a test needs the message list
  together with a field no accessor covers (the active worker,
  `cancelled`); everywhere else the public accessor serves the read.
  PubSub broadcasts are the externally visible contract
  (chat:message, chat:status).
  """
  use Nest.DataCase, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  defp message_indices(messages) do
    messages
    |> Enum.flat_map(fn
      {_, %{index: idx}} -> [idx]
      _ -> []
    end)
  end

  describe "single-iteration turn" do
    test "1.1.1 appends user + assistant, transitions to idle" do
      MockClient.set_response("Hello back")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      # allowlist: snapshot — work + cancelled + messages
      state = :sys.get_state(pid, 1_000)

      assert state.live.machine.work.active_worker == nil
      assert state.live.cancelled == false

      indices = message_indices(state.chat_state.messages)

      assert length(state.chat_state.messages) == 3
      assert hd(state.chat_state.messages) |> elem(0) == :system
      assert {:user, %{} = user} = Enum.at(state.chat_state.messages, 1)
      assert {:assistant, %Assistant{} = assistant} = Enum.at(state.chat_state.messages, 2)

      assert user.index == 1
      assert assistant.index == 2

      assert [%Nest.Messages.Part.Text{text: text} | _] = assistant.parts
      assert text == "Hello back"

      assert indices == Enum.sort(indices)
      assert Enum.uniq(indices) == indices
    end
  end

  describe "multi-iteration turn" do
    test "1.1.2 tool call then final response: messages with sequential indices" do
      MockClient.set_tool_response(%{
        text: "Calling a tool",
        tool_calls: [
          %{id: "call_1", name: "shell-cmd", arguments: %{"command" => "echo hi"}}
        ]
      })

      MockClient.set_response("Tool result was hi")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Run a command")

      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      messages = Agent.get_messages(pid, 1_000)

      # Expected base: system(0), user(1), assistant+tools(2),
      # tool(3), final_assistant(4). The context-notice synthetic
      # pair may add 2 more messages at any LLM-response boundary
      # that crosses a threshold, depending on the test model's
      # resolved context_limit. We assert on indices being unique
      # and sequential, not on a fixed count.
      indices = message_indices(messages)

      assert length(indices) >= 5
      assert indices == Enum.sort(indices), "indices must be sorted"
      assert length(Enum.uniq(indices)) == length(indices), "indices must be unique"
    end
  end

  describe "multi-turn monotonic indices" do
    test "1.1.8 two chats: indices strictly monotonic, no gaps, no duplicates" do
      MockClient.set_response("First")
      MockClient.set_response("Second")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "First chat")
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      :ok = Agent.chat(pid, "Second chat")
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      messages = Agent.get_messages(pid, 1_000)
      indices = message_indices(messages)

      # The two chats should produce: system (0), user1 (1),
      # asst1 (2), user2 (3), asst2 (4) — 5 messages with
      # indices [0, 1, 2, 3, 4].
      assert indices == [0, 1, 2, 3, 4],
             "expected indices [0, 1, 2, 3, 4], got #{inspect(indices)}"

      AgentTestHelpers.assert_unique_message_indices(messages)
    end
  end
end
