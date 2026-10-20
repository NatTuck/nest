defmodule Nest.Agents.AgentContextWarningTest do
  @moduledoc """
  Regression coverage for the "context-usage warning fires on every
  user message past 25%" bug.

  The "already announced" set lives on
  `state.live.crossed_thresholds` (per conversation, not per turn);
  the in-process turn reads it directly from the Agent state and
  writes the updated set back. Cleared on successful compaction in
  `Machine.Compaction`. The pure unit tests for
  `ContextReminder.highest_unannounced/3` live in
  `test/nest/agents/agent/turn/context_reminder_test.exs`;
  this module covers the wiring.
  """

  use Nest.DataCase, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.AgentTestHelpers
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.User

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
    :sys.replace_state(
      pid,
      fn state ->
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
      end,
      1_000
    )
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

  defp stamped_notice?({_role, %{metadata: %{"context_threshold" => _}}}), do: true
  defp stamped_notice?(_), do: false

  @tag timeout: 2_000
  test "fires :p25 once across multiple user messages past 25%" do
    {pid, _agent_id} = AgentTestHelpers.start_agent(%{})

    seed_past_25_percent(pid)

    :ok = Agent.chat(pid, "First message")
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    :ok = Agent.chat(pid, "Second message")
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    :ok = Agent.chat(pid, "Third message")
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    # allowlist: snapshot — messages + context_projection
    state = :sys.get_state(pid, 1_000)

    assert count_reminders(state, "Context at 25%") == 1,
           "expected exactly one :p25 reminder across three user messages, " <>
             "got #{count_reminders(state, "Context at 25%")}"

    # The injected notice is stamped with its threshold so the
    # announced set can be rebuilt after a BEAM restart.
    assert Enum.any?(state.chat_state.messages, &stamped_notice?/1),
           "expected the fired reminder to carry context_threshold metadata"

    # The turn went idle, so any forward-looking projection was cleared.
    assert state.live.context_projection == nil
  end

  test "compaction_done clears crossed_thresholds so the next turn can re-fire" do
    {pid, _agent_id} = AgentTestHelpers.start_agent(%{})

    :sys.replace_state(
      pid,
      fn state ->
        # Seeded messages are short enough that any post-compaction
        # turn will be well under 25% of the working budget,
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
      end,
      1_000
    )

    AgentTestHelpers.send_compaction_done(pid, "Summary", nil)

    # The handler resets the set BEFORE starting the next turn.
    # The next turn runs an iteration (against the short seeded
    # messages, well under 25%) and finalizes to :idle. After that
    # the field must still be empty (no reminder fires).
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    crossed = Agent.get_crossed_thresholds(pid, 1_000)

    assert crossed == %MapSet{},
           "expected crossed_thresholds cleared after compaction, " <>
             "got #{inspect(crossed)}"
  end
end
