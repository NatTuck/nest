defmodule Nest.Agents.AgentSystemMessagesTest do
  @moduledoc """
  Integration tests for the system-message flow: the initial
  `{:system, _}` message at position 0 of `state.chat_state.messages`,
  and the budget-remaining notice injected as a synthetic pair
  before the LLM's response.

  The budget reminder is delivered as a
  `[assistant("Tool limit?"), user(notice)]` pair immediately
  before the LLM's response that would exceed the iteration
  budget. The attention text is "Tool limit?" — type-specific,
  not the generic "Context?" used for context-usage threshold
  notices.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: SystemMsg

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "initial system message" do
    test "the agent's messages list always starts with a {:system, _} message" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      state = :sys.get_state(pid)
      first = hd(state.chat_state.messages)

      assert match?({:system, %SystemMsg{}}, first)
    end

    test "the system message is in state (transparency)" do
      {pid, _agent_id} = start_agent()

      messages = Nest.Agents.Agent.get_messages(pid)

      # Transparency: the system message is always the first
      # entry in the messages list, never hidden. It is
      # non-empty whenever the agent was created with a
      # real vocation (the default `start_agent/1` path).
      assert {:system, %SystemMsg{parts: [%Part.Text{text: text}]}} = hd(messages)
      assert text != ""
    end
  end

  describe "budget reminder injected as synthetic pair" do
    test "the budget warning is delivered as a user message in a synthetic pair before the LLM's response" do
      for i <- 1..4 do
        MockClient.set_tool_response(%{
          text: "loop #{i}",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      MockClient.set_response("All done, used tools 4 times")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      capture_log(fn ->
        :ok = Agent.chat(pid, "Loop until done")
        assert_receive {:chat_status, %{status: "idle"}}, 5000
      end)

      state = :sys.get_state(pid)

      # The budget reminder is a {:user, _} message containing
      # the notice text, preceded by a {:assistant, _} attention
      # message with the type-specific "Tool limit?" text.
      # Find both.
      user_messages =
        Enum.filter(state.chat_state.messages, fn
          {:user, %Nest.Messages.User{parts: parts}} ->
            Enum.any?(parts, fn
              %Part.Text{text: text} -> String.contains?(text, "tool call rounds remaining")
              _ -> false
            end)

          _ ->
            false
        end)

      assert user_messages != [],
             "expected a user message containing the budget reminder notice"

      attention_messages =
        Enum.filter(state.chat_state.messages, fn
          {:assistant, %Nest.Messages.Assistant{parts: [%Part.Text{text: "Tool limit?"}]}} -> true
          _ -> false
        end)

      assert attention_messages != [],
             "expected a preceding synthetic assistant message with the 'Tool limit?' attention text"
    end

    test "the budget reminder and the final response get distinct indices (regression: dual-counter bug)" do
      for i <- 1..4 do
        MockClient.set_tool_response(%{
          text: "loop #{i}",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      MockClient.set_response("All done, used tools 4 times")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      capture_log(fn ->
        :ok = Agent.chat(pid, "Loop until done")
        assert_receive {:chat_status, %{status: "idle"}}, 5000
      end)

      state = :sys.get_state(pid)

      # The final assistant has a different index from the
      # budget-reminder user message (regression: dual-counter
      # bug — the synthetic pair must be stamped before the
      # final response).
      {:assistant, final} = List.last(state.chat_state.messages)

      user_reminder =
        Enum.find(state.chat_state.messages, fn
          {:user, %Nest.Messages.User{parts: parts}} ->
            Enum.any?(parts, fn
              %Part.Text{text: text} -> String.contains?(text, "tool call rounds remaining")
              _ -> false
            end)

          _ ->
            false
        end)

      assert user_reminder, "expected a user message containing the budget reminder notice"
      {:user, reminder} = user_reminder

      assert final.index != reminder.index,
             "final assistant (#{final.index}) and budget reminder (#{reminder.index}) share an index"
    end

    test "back-to-back: budget and context reminders both inject their own pairs" do
      # When both reminders fire on the same iteration, each
      # gets its own synthetic pair with its own attention text.
      # Budget first (it's the more urgent signal), then context.
      # We don't defer or combine — the LLM sees both, the UI
      # shows both.
      #
      # Setup: seed a conversation past 25% so the context
      # threshold fires via the pipeline Case 1, and drive
      # enough tool iterations that the budget also fires.
      for i <- 1..4 do
        MockClient.set_tool_response(%{
          text: "loop #{i}",
          tool_calls: [
            %{
              id: "call_#{:rand.uniform(100_000)}",
              name: "shell_cmd",
              arguments: %{"command" => "echo loop"}
            }
          ]
        })
      end

      MockClient.set_response("All done")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      # Force the context threshold to cross by seeding a
      # large user body and a small context_limit. The Case 1
      # pipeline injection fires on the user message arrival.
      :sys.replace_state(pid, fn st ->
        big_text = String.duplicate("x", 4_000)

        messages = [
          {:system,
           %SystemMsg{
             index: 0,
             parts: [%Part.Text{text: "Test system prompt."}],
             api_logs: []
           }},
          {:user,
           %Nest.Messages.User{index: 1, parts: [%Part.Text{text: big_text}], api_logs: []}}
        ]

        %{
          st
          | chat_state: %{st.chat_state | messages: messages},
            llm_metrics: %{st.llm_metrics | context_limit: 10_000}
        }
      end)

      :ok = Agent.chat(pid, "Loop until done")
      assert_receive {:chat_status, %{status: "idle"}}, 5000

      state = :sys.get_state(pid)

      # With context_limit: 10_000, the 4000-char user body
      # (~643 tokens) crosses 25% (working budget ~1808 / 4
      # = 452). The Case 1 pipeline injects a "Context?"
      # pair on user-message arrival. Then the budget fires
      # during tool execution and the Case 2 response handler
      # injects a "Tool limit?" pair. So we expect BOTH
      # attention texts in the final messages list.
      tool_limit_attentions =
        Enum.filter(state.chat_state.messages, fn
          {:assistant, %Nest.Messages.Assistant{parts: [%Part.Text{text: "Tool limit?"}]}} -> true
          _ -> false
        end)

      context_attentions =
        Enum.filter(state.chat_state.messages, fn
          {:assistant, %Nest.Messages.Assistant{parts: [%Part.Text{text: "Context?"}]}} -> true
          _ -> false
        end)

      assert tool_limit_attentions != [],
             "expected a 'Tool limit?' attention message in the back-to-back case"

      assert context_attentions != [],
             "expected a 'Context?' attention message in the back-to-back case"

      # The two attention messages are distinct synthetic
      # messages in the list. They both have type-specific
      # attention text — no cross-contamination.
      assert tool_limit_attentions != [],
             "expected at least one 'Tool limit?' attention"

      assert context_attentions != [],
             "expected at least one 'Context?' attention"

      # The user messages containing the notices also each
      # have type-specific content: budget says "tool call rounds",
      # context says "token budget".
      budget_user_messages =
        Enum.filter(state.chat_state.messages, fn
          {:user, %Nest.Messages.User{parts: parts}} ->
            Enum.any?(parts, fn
              %Part.Text{text: text} -> String.contains?(text, "tool call rounds")
              _ -> false
            end)

          _ ->
            false
        end)

      context_user_messages =
        Enum.filter(state.chat_state.messages, fn
          {:user, %Nest.Messages.User{parts: parts}} ->
            Enum.any?(parts, fn
              %Part.Text{text: text} -> String.contains?(text, "token budget")
              _ -> false
            end)

          _ ->
            false
        end)

      assert budget_user_messages != [],
             "expected at least one user message with budget notice"

      assert context_user_messages != [],
             "expected at least one user message with context notice"
    end
  end
end
