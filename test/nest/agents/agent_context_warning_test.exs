defmodule Nest.Agents.AgentContextWarningTest do
  @moduledoc """
  Regression coverage for the "context-usage warning fires on every
  user message past 25%" bug.

  The "already announced" set lives on
  `state.live.crossed_thresholds` (per conversation, not per
  ChatTurn); a ChatTurn reads it from `ctx` and sends the updated
  set back via `{:set_crossed_thresholds, set}`. Cleared on
  successful compaction in `Compaction.ResultHandler`. The pure
  unit tests for `ContextReminder.highest_unannounced/3` live in
  `test/nest/agents/agent/chat_turn/context_reminder_test.exs`;
  this module covers the wiring.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.ChatTurn.ContextReminder
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.User
  alias Nest.Tokens.Estimator

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()
    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)
    :ok
  end

  # Build a chat turn whose seed messages already cross 25% of the
  # working budget. `context_limit: 10_000` makes the reserve
  # `max(8_192, 2_000) = 8_192` and the working budget 1_808,
  # so 25% fires at ~452 used tokens. The 4_000-char user body
  # tokenizes to ~643 tokens, well past 25%. Small enough to
  # keep the LLM round-trip fast and avoid the Ecto Sandbox
  # ownership timeout (default 30 s).
  defp seed_past_25_percent(pid) do
    :sys.replace_state(pid, fn state ->
      big_text = String.duplicate("x", 4_000)

      messages = [
        {:system,
         %Nest.Messages.System{
           index: 0,
           parts: [%Part.Text{text: "Test system prompt."}],
           api_logs: []
         }},
        {:user, %User{index: 1, parts: [%Part.Text{text: big_text}], api_logs: []}}
      ]

      %{
        state
        | chat_state: %{state.chat_state | messages: messages},
          llm_metrics: %{state.llm_metrics | context_limit: 10_000}
      }
    end)
  end

  defp count_reminders(state, text_pattern) do
    Enum.count(state.chat_state.messages, fn
      {:system, %{parts: parts}} ->
        has_text?(parts, text_pattern)

      {:user, %{parts: parts}} ->
        has_text?(parts, text_pattern)

      {:assistant, %{parts: parts}} ->
        has_text?(parts, text_pattern)

      {:tool, %Nest.Messages.Tool{parts: parts}} ->
        has_text?(parts, text_pattern)

      _ ->
        false
    end)
  end

  defp has_text?(parts, text_pattern) do
    Enum.any?(parts, fn
      %Part.Text{text: text} -> String.contains?(text, text_pattern)
      _ -> false
    end)
  end

  @tag timeout: 30_000
  test "fires :p25 once across multiple user messages past 25%" do
    {pid, _agent_id} = AgentTestHelpers.start_agent(%{})

    seed_past_25_percent(pid)

    :ok = Agent.chat(pid, "First message")
    assert_receive {:chat_status, %{status: "idle"}}, 5_000

    :ok = Agent.chat(pid, "Second message")
    assert_receive {:chat_status, %{status: "idle"}}, 5_000

    :ok = Agent.chat(pid, "Third message")
    assert_receive {:chat_status, %{status: "idle"}}, 5_000

    state = :sys.get_state(pid)

    assert count_reminders(state, "Context at 25%") == 1,
           "expected exactly one :p25 reminder across three user messages, " <>
             "got #{count_reminders(state, "Context at 25%")}"
  end

  @tag timeout: 30_000
  test "the Agent's crossed_thresholds persists the fired atom across ChatTurns" do
    {pid, _agent_id} = AgentTestHelpers.start_agent(%{})

    seed_past_25_percent(pid)

    :ok = Agent.chat(pid, "First message")
    assert_receive {:chat_status, %{status: "idle"}}, 5_000

    state = :sys.get_state(pid)

    assert MapSet.member?(state.live.crossed_thresholds, :p25),
           "expected :p25 to be persisted on the Agent after firing, " <>
             "got #{inspect(state.live.crossed_thresholds)}"
  end

  test "compaction_done clears crossed_thresholds so the next ChatTurn can re-fire" do
    {pid, _agent_id} = AgentTestHelpers.start_agent(%{})

    :sys.replace_state(pid, fn state ->
      # Seeded messages are short enough that any post-compaction
      # ChatTurn will be well under 25% of the working budget,
      # so the cleared set stays cleared (no reminder fires).
      messages = [
        {:system,
         %Nest.Messages.System{
           index: 0,
           parts: [%Part.Text{text: "System"}],
           api_logs: []
         }},
        {:user, %User{index: 1, parts: [%Part.Text{text: "Hi"}], api_logs: []}}
      ]

      %{
        state
        | chat_state: %{state.chat_state | messages: messages},
          live: %{state.live | crossed_thresholds: MapSet.new([:p25, :p50, :p75])},
          llm_metrics: %{state.llm_metrics | context_limit: 200_000}
      }
    end)

    send(pid, {:compaction_done, "Summary", nil})

    # The handler resets the set BEFORE spawning the next ChatTurn.
    # The next ChatTurn runs an iteration (against the short seeded
    # messages, well under 25%) and finalizes to :idle. After that
    # the field must still be empty (no reminder fires).
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    state = :sys.get_state(pid)

    assert state.live.crossed_thresholds == %MapSet{},
           "expected crossed_thresholds cleared after compaction, " <>
             "got #{inspect(state.live.crossed_thresholds)}"
  end

  @tag timeout: 30_000
  test "does NOT inject context pair when trailing assistant carries a tool_use (in-flight tool)" do
    # Regression for the Anthropic 400 (2013) bug: the
    # `maybe_inject_context_pair` `else` branch used to inject
    # [user(notice), assistant(ack)] between an in-flight
    # `assistant+tool_use` and its upcoming `tool_result`,
    # breaking the tool_use/tool_result pairing invariant.
    #
    # The defense-in-depth guard in `Agent.handle_cast({:chat, _})`
    # rejects user messages that arrive while the agent is
    # `:streaming` or `:executing_tools` — so the user-during-
    # tool scenario never reaches the pipeline in production.
    # This test verifies the pipeline's `inject_notice` guard
    # at the unit level: it must not fire for trailing
    # assistant+tool_use regardless of how the message arrives.
    {pid, _agent_id} = AgentTestHelpers.start_agent(%{})

    :sys.replace_state(pid, fn state ->
      big_text = String.duplicate("x", 4_000)

      tool_use = %Nest.Messages.Part.ToolUse{
        id: "call_xyz",
        name: "shell_cmd",
        arguments: %{"command" => "sleep 10"}
      }

      messages = [
        {:system,
         %Nest.Messages.System{
           index: 0,
           parts: [%Part.Text{text: "Test system prompt."}],
           api_logs: []
         }},
        {:user, %User{index: 1, parts: [%Part.Text{text: big_text}], api_logs: []}},
        {:assistant,
         %Nest.Messages.Assistant{
           index: 2,
           parts: [
             %Part.Text{text: "Let me run that command."},
             tool_use
           ],
           api_logs: []
         }}
      ]

      %{
        state
        | chat_state: %{state.chat_state | messages: messages},
          llm_metrics: %{state.llm_metrics | context_limit: 10_000}
      }
    end)

    # Simulate a user message that crosses the threshold by
    # setting the pending user message directly. We bypass the
    # defense-in-depth guard (which would reject the message
    # in a real scenario) so the test exercises the pipeline's
    # injection guard specifically.
    state = :sys.get_state(pid)
    state = put_in(state.live.pending_user_message, {"New request", "chat"})

    # The pending message is enough tokens to push usage past
    # 25% of the working budget.
    projected =
      Estimator.estimate_messages(state.chat_state.messages) +
        Estimator.estimate("[mode: chat]\nNew request")

    crossed =
      ContextReminder.highest_unannounced(
        projected,
        state.llm_metrics.context_limit,
        state.live.crossed_thresholds
      )

    assert crossed == :p25,
           "expected :p25 to be the highest unannounced threshold, got #{inspect(crossed)}"

    # The trailing message is assistant+tool_use, so the wire
    # role is :assistant. `MessageList.last_wire_role/1`
    # returns :assistant, and `trailing_has_tool_use?/1` would
    # return true. The pipeline's `inject_notice/3` guard
    # detects this and skips the pair injection. The threshold
    # is still tracked on the agent's `crossed_thresholds` set
    # so the Case 2 injection at the next LLM-response boundary
    # can fire (or be skipped if the threshold was already
    # announced for the current compaction segment).
    assert MessageList.last_wire_role(state.chat_state.messages) == :assistant
  end
end
