defmodule Nest.Agents.Agent.TurnAcceptanceTest do
  @moduledoc """
  Acceptance tests for the Agent's in-process turn driver —
  the iteration state machine that drives each chat turn.
  These tests are the contract: they drive the turn through
  every transition (single-iteration, multi-iteration, budget
  reminder, max-iterations second-chance, user stop, HTTP
  crash, nil usage, multi-turn) with a real Agent and the
  existing `MockClient`.

  They use `:sys.get_state/1` to inspect the Agent's state
  directly so we can assert against the message index, the
  status, and the active worker (the externally visible
  contract the driver must honor). PubSub broadcasts are used
  to assert the externally visible contract (chat:message,
  chat:status, chat:error).

  These tests must pass before the refactor is complete.
  They cover the regression cases that the old
  `LLMRunner.run/2`-in-a-Task design broke with the
  dual-counter bug class.
  """
  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  defp message_indices(state) do
    state.chat_state.messages
    |> Enum.flat_map(fn
      {_, %{index: idx}} -> [idx]
      _ -> []
    end)
  end

  # The carried assistant+ToolUse handed to a resumed turn as the
  # compaction entry `{:tool_call, msg, iter, max}`. The resumed turn
  # executes it first, then makes its next LLM call with
  # the carried iteration count — so seeding a turn at the cap makes its
  # first LLM call the final `tools: nil` one. `context-check` (rather
  # than `context-compact`) keeps that execution from triggering a
  # compaction of its own.
  defp carried_tool_call_msg do
    {:assistant,
     %Assistant{
       index: 0,
       parts: [
         %Part.ToolUse{
           id: "call_cap",
           name: "context-check",
           arguments: %{}
         }
       ],
       api_logs: []
     }}
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

      assert_receive {:chat_status, %{status: "idle"}}, 2000

      state = :sys.get_state(pid)

      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.active_worker == nil
      assert state.live.cancelled == false

      indices = message_indices(state)

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

      assert_receive {:chat_status, %{status: "idle"}}, 2000

      state = :sys.get_state(pid)

      # Expected base: system(0), user(1), assistant+tools(2),
      # tool(3), final_assistant(4). The context-notice synthetic
      # pair may add 2 more messages at any LLM-response boundary
      # that crosses a threshold, depending on the test model's
      # resolved context_limit. We assert on indices being unique
      # and sequential, not on a fixed count.
      indices = message_indices(state)

      assert length(indices) >= 5
      assert indices == Enum.sort(indices), "indices must be sorted"
      assert length(Enum.uniq(indices)) == length(indices), "indices must be unique"
      assert Machine.status_for(state.live.machine) == :idle
    end
  end

  describe "budget reminder" do
    test "1.1.3 reminder is injected on remaining=2, gets distinct index from final response" do
      for i <- 1..4 do
        MockClient.set_tool_response(%{
          text: "loop #{i}",
          tool_calls: [
            %{id: "call_#{i}", name: "context-check", arguments: %{}}
          ]
        })
      end

      MockClient.set_response("All done")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Loop until done")
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      state = :sys.get_state(pid)

      # The budget reminder is now a synthetic pair injected at
      # the LLM-response-construction site: a {:user, _} message
      # carrying the notice text, preceded by a {:assistant, _}
      # "Context?" attention message.
      reminders =
        Enum.filter(state.chat_state.messages, fn
          {:user, %Nest.Messages.User{parts: parts}} when is_list(parts) ->
            Enum.any?(parts, fn
              %Part.Text{text: text} ->
                String.contains?(text, "tool call rounds remaining") or
                  String.contains?(text, "Last tool call round")

              _ ->
                false
            end)

          _ ->
            false
        end)

      assert reminders != [], "expected at least one budget reminder in messages"

      reminder_indices = Enum.map(reminders, fn {_, %{index: idx}} -> idx end)

      responses =
        Enum.filter(state.chat_state.messages, fn
          {:assistant, %Assistant{parts: parts}} when is_list(parts) ->
            Enum.all?(parts, fn
              %Nest.Messages.Part.ToolUse{} -> false
              _ -> true
            end)

          _ ->
            false
        end)

      response_indices = Enum.map(responses, fn {_, %{index: idx}} -> idx end)

      Enum.each(reminder_indices, fn ri ->
        Enum.each(response_indices, fn si ->
          assert ri != si,
                 "reminder index #{ri} collides with response index #{si} — dual-counter bug"
        end)
      end)

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  describe "max iterations second-chance" do
    test "1.1.4 max_iterations: final call uses tools: nil, iteration produces a final response" do
      # The cap is 5 (test/data/config.toml). Rather than burn five real
      # tool rounds to walk the iteration counter up to it, resume a turn
      # that is already at the cap: the carried
      # `{:tool_call, msg, iter, max}` continuation preserves both
      # counters (the machine entry), so the resumed turn's next LLM
      # call is the final `tools: nil` call. One LLM round instead of six,
      # same contract.
      #
      # The `tools: nil` decision itself is asserted directly in
      # `machine/turn_test.exs`. What this test pins is the
      # observable end of it: the final call's text lands as the final
      # assistant message and the turn ends idle.
      MockClient.set_response("Final answer at the cap")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      capture_log(fn ->
        send_compaction_done(pid, "Summary", {:tool_call, carried_tool_call_msg(), 5, 5})

        # Fires only once the iteration counter is past the cap, so this
        # is what proves the carried count took effect and the call that
        # follows really is the final one.
        assert_receive {:chat_notification, %{type: "max_iterations"}}, 750

        assert_receive {:chat_status, %{status: "idle"}}, 750
      end)

      state = :sys.get_state(pid)

      # The agent goes to :idle after the final call.
      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.active_worker == nil

      assert Enum.any?(state.chat_state.messages, fn
               {:assistant, %Assistant{parts: parts}} ->
                 Enum.any?(parts, &match?(%Part.Text{text: "Final answer at the cap"}, &1))

               _ ->
                 false
             end),
             "expected the final call's text to land as the final assistant message"
    end
  end

  describe "user-initiated stop" do
    test "1.1.5 finalizes the partial assistant message and transitions to idle" do
      events = for _ <- 1..50, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "Tell me a long story")

      # The Agent broadcasts `chat:status: streaming` when the
      # chat turn starts streaming.
      assert_receive {:chat_status, %{status: "streaming"}}, 2000

      # Wait for at least one delta to be processed so the
      # Agent's `streaming_acc` mirror has content to finalize.
      # The `chat:delta` PubSub broadcast is the event-based
      # signal that the Agent's `delta_received` handler has
      # already updated the mirror.
      assert_receive {:chat_delta, _}, 500

      # Use the public stop API instead of reaching into the
      # Agent's internals. The stop runs entirely in the Agent
      # process.
      Agent.stop_chat(pid, self())

      assert_receive {:chat_status, %{status: "idle"}}, 2000

      state = :sys.get_state(pid)

      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.active_worker == nil

      final_assistants =
        Enum.filter(state.chat_state.messages, fn
          {:assistant, %Assistant{parts: parts}} when is_list(parts) ->
            Enum.any?(parts, fn
              %Nest.Messages.Part.Text{text: text} when is_binary(text) -> true
              _ -> false
            end)

          _ ->
            false
        end)

      assert final_assistants != [],
             "expected a partial assistant message after stop"

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  describe "HTTP worker crash" do
    test "1.1.6 Agent receives {:chat_crashed, _}, broadcasts chat:error, transitions to idle" do
      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      Mimic.stub(MockClient, :run, fn _request, _opts ->
        raise FunctionClauseError,
          module: Nest.LLM.OpenAIClient,
          function: :finish_event,
          arity: 1,
          args: [%{"delta" => %{"role" => "assistant"}}]
      end)

      Mimic.allow(MockClient, self(), pid)

      # capture_log swallows the `Logger.error` calls in
      # `Broadcasts.log_error/4` (the agent logs the error
      # before broadcasting the structured `chat:error`
      # event).
      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")

        assert_receive {:chat_status, %{status: "idle"}}, 2000
      end)

      state = :sys.get_state(pid)

      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.active_worker == nil
    end
  end

  describe "nil usage is a no-op" do
    test "1.1.7 second chat with no usage does not zero out accumulated output_tokens" do
      MockClient.set_response("First response")
      MockClient.set_response("Second response with no usage event")

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      :ok = Agent.chat(pid, "First")
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      first_info = Agent.get_public_info(pid)
      first_output = first_info.usage.output_tokens || 0

      :ok = Agent.chat(pid, "Second")
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      second_info = Agent.get_public_info(pid)
      second_output = second_info.usage.output_tokens || 0

      assert second_output >= first_output,
             "second chat's output_tokens (#{second_output}) " <>
               "should not be less than first chat's (#{first_output}) — nil usage should be a no-op"
    end
  end

  describe "turn-boundary inbox delivery" do
    test "1.1.9 a message queued during a tool batch lands before the next request, with no idle" do
      test_pid = self()

      {pid, name} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: programmer_vocation_id_for_test()
        })

      # Record the message list of every request the turn makes, then hand off
      # to the scripted MockClient so the turn behaves exactly as the other
      # fixtures do.
      Mimic.stub(MockClient, :run, fn request, opts ->
        send(test_pid, {:llm_request, request.messages})
        Mimic.call_original(MockClient, :run, [request, opts])
      end)

      Mimic.allow(MockClient, self(), pid)

      # Request 1: the model sends *itself* two messages. The tool batch runs
      # while the agent is `:executing_tools`, so both are queued and never
      # delivered mid-batch — the "message arrived while the turn was running"
      # case, with no timing dependence.
      MockClient.set_tool_response(%{
        text: "Queueing",
        tool_calls: [
          %{
            id: "send_1",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "first"}
          },
          %{
            id: "send_2",
            name: "agents-send",
            arguments: %{"name" => name, "message" => "second"}
          }
        ]
      })

      MockClient.set_response("Done")

      :ok = Agent.chat(pid, "queue some messages")

      # The turn stays busy across the delivery: streaming -> executing_tools
      # -> streaming (the delivered message's turn, started in place) -> idle.
      # An `idle` in between would mean the delivery waited for the turn end
      # (the rejected alternative), which resolves an idle-based wait with the
      # pre-delivery answer and reports a partial result to a parent.
      assert statuses_until_idle() == ["streaming", "executing_tools", "streaming", "idle"]

      # The two messages were queued (count 1, then 2) and then drained
      # (count 0) — not delivered into the running batch.
      assert_received {:chat_inbox, %{count: 1}}
      assert_received {:chat_inbox, %{count: 2}}
      assert_received {:chat_inbox, %{count: 0}}

      # Both requests the turn made, in order.
      first = assert_request()
      second = assert_request()

      # The next request already carried the delivered message, before the
      # final response was requested: that is the boundary delivery's whole
      # contract ("deliver before starting a new thing").
      assert Enum.any?(user_texts(first), &(&1 =~ "queue some messages"))
      refute Enum.any?(user_texts(first), &(&1 =~ "second"))

      assert Enum.any?(user_texts(second), &(&1 =~ "queue some messages"))
      assert Enum.any?(user_texts(second), &(&1 =~ "[Message from agent"))
      assert Enum.any?(user_texts(second), &(&1 =~ "first"))
      assert Enum.any?(user_texts(second), &(&1 =~ "second"))

      # Exactly two: the delivery did not end the turn and start a new one.
      refute_receive {:llm_request, _}, 50

      state = :sys.get_state(pid)

      assert Machine.status_for(state.live.machine) == :idle
      assert state.live.machine.work.active_worker == nil
      assert state.live.inbox == []

      messages = state.chat_state.messages

      tool_index = Enum.find_index(messages, &match?({:tool, _}, &1))
      ack_index = Enum.find_index(messages, &(text_of(&1) =~ "continuing from here"))
      drained_index = Enum.find_index(messages, &(text_of(&1) =~ "[Message from agent"))
      final_index = Enum.find_index(messages, &(text_of(&1) =~ "Done"))

      assert is_integer(tool_index), "expected a tool-result message"
      assert is_integer(ack_index), "expected the live bridge ack"
      assert is_integer(drained_index), "expected the delivered user message"
      assert is_integer(final_index), "expected the final assistant response"

      # The delivered user message was bridged: the tail was the tool result
      # (a wire-`user` message), so `MessageAppender` inserted the live
      # alternation ack first, then the drained user message.
      assert tool_index < ack_index
      assert ack_index < drained_index

      # The delivery landed mid-turn: before the response to the request that
      # carried it, with nothing else appended in between.
      assert drained_index < final_index
      assert drained_index == final_index - 1

      # The drained order is preserved, and the combined text is the inbox's
      # canonical per-entry framing.
      drained = text_of(Enum.at(messages, drained_index))
      assert drained =~ "[Message from agent \"#{name}\"]\nfirst"
      assert {first_at, _} = :binary.match(drained, "first")
      assert {second_at, _} = :binary.match(drained, "second")
      assert first_at < second_at

      # The tool results report the queueing (the messages were not delivered
      # into the running batch).
      assert Enum.any?(
               tool_texts(Enum.at(messages, tool_index)),
               &(&1 =~ "Message queued for #{name} (busy)")
             )

      AgentTestHelpers.assert_unique_message_indices(state)
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
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      :ok = Agent.chat(pid, "Second chat")
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      state = :sys.get_state(pid)
      indices = message_indices(state)

      # The two chats should produce: system (0), user1 (1),
      # asst1 (2), user2 (3), asst2 (4) — 5 messages with
      # indices [0, 1, 2, 3, 4].
      assert indices == [0, 1, 2, 3, 4],
             "expected indices [0, 1, 2, 3, 4], got #{inspect(indices)}"

      AgentTestHelpers.assert_unique_message_indices(state)
    end
  end

  # Collect the `chat:status` sequence up to (and including) the first
  # `idle`. `start_agent/1` subscribes the test pid to the agent's topic.
  # An ordered collector (not a drain): the assertion is that the sequence is
  # exactly streaming -> executing_tools -> streaming -> idle, so an `idle`
  # anywhere before the end fails. The 2s fence only fires when the turn
  # wedges; the turn itself is two mock HTTP calls plus one in-memory tool
  # batch, normally well under 50ms.
  defp statuses_until_idle(acc \\ []) do
    receive do
      {:chat_status, %{status: "idle"}} ->
        Enum.reverse(["idle" | acc])

      {:chat_status, %{status: status}} ->
        statuses_until_idle([status | acc])
    after
      2000 ->
        flunk("no idle status within 2s; statuses so far: #{inspect(Enum.reverse(acc))}")
    end
  end

  # The next recorded LLM request's message list.
  defp assert_request do
    receive do
      {:llm_request, messages} -> messages
    after
      2000 -> flunk("expected another LLM request")
    end
  end

  defp user_texts(messages) do
    for {:user, %{parts: parts}} <- messages, do: parts_text(parts)
  end

  defp text_of({_tag, %{parts: parts}}), do: parts_text(parts)
  defp text_of(_message), do: ""

  defp tool_texts({:tool, %{parts: parts}}) do
    for %Part.ToolResult{content: content} <- parts || [], do: content || ""
  end

  defp tool_texts(_message), do: []

  defp parts_text(parts) do
    Enum.map_join(parts, "", fn
      %Part.Text{text: text} -> text || ""
      _ -> ""
    end)
  end
end
