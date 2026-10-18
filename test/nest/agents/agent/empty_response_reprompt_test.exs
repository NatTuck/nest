defmodule Nest.Agents.Agent.EmptyResponseRepromptTest do
  @moduledoc """
  Tests for the empty-response re-prompt.

  A model can end a turn having streamed only reasoning
  (`reasoning_content`) and no actual reply text. The turn used to
  treat that as a finished answer, leaving the user with a thinking-
  only "reply" and a dead conversation. Now `Machine.Response`
  detects a silent response (no text, no refusal), injects an explicit
  user nudge, and re-asks — bounded by `@max_empty_retries` — before
  giving up and finalizing.
  """

  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part

  import Nest.Agents.AgentTestHelpers

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  # A canned LLM response that streams reasoning but no text — the
  # shape that used to end the conversation silently.
  defp silent_response_events do
    [
      {:thinking, "I reasoned it all out but forgot to actually say anything."},
      {:finish_reason, "stop"}
    ]
  end

  test "a silent response is re-prompted once, then the real reply lands" do
    {pid, _name} = start_agent()

    # First LLM call: thinking only, no text. Second: a real reply.
    MockClient.set_stream_events(silent_response_events())
    MockClient.set_response("Here is my actual reply.")

    :ok = Agent.chat(pid, "Analyze the lab")

    assert_receive {:chat_message, {:user, %{index: 1}}}, 1_000

    # The silent assistant (thinking only) is still shown...
    assert_receive {:chat_message, {:assistant, %{index: 2, parts: [%Part.Thinking{}]}}}, 1_000

    # ...but the model is asked to actually speak.
    assert_receive {:chat_message, {:user, %{index: 3, parts: [%Part.Text{text: nudge}]}}}, 1_000
    assert nudge =~ "empty response"
    assert nudge =~ "[From nest runtime"

    # And this time it replies with real text.
    assert_receive {:chat_message, {:assistant, %{index: 4, parts: parts}}},
                   500

    assert Enum.any?(parts, &match?(%Part.Text{text: "Here is my actual reply."}, &1))

    assert_receive {:chat_status, %{status: "idle"}}, 1_000
  end

  test "after the retry cap the turn finalizes with a warning (no infinite loop)" do
    {pid, _name} = start_agent()

    # Three consecutive silent responses: two nudge re-prompts, then
    # give up at the cap.
    for _ <- 1..3, do: MockClient.set_stream_events(silent_response_events())

    log =
      capture_log(fn ->
        :ok = Agent.chat(pid, "Analyze the lab")

        assert_receive {:chat_message, {:user, %{index: 1}}}, 1_000

        assert_receive {:chat_message, {:assistant, %{index: 2, parts: [%Part.Thinking{}]}}},
                       1_000

        assert_receive {:chat_message, {:user, %{index: 3}}}, 1_000

        assert_receive {:chat_message, {:assistant, %{index: 4, parts: [%Part.Thinking{}]}}},
                       1_000

        assert_receive {:chat_message, {:user, %{index: 5}}}, 1_000

        assert_receive {:chat_message, {:assistant, %{index: 6, parts: [%Part.Thinking{}]}}},
                       1_000

        assert_receive {:chat_status, %{status: "idle"}}, 1_000
      end)

    assert log =~ "Empty assistant response finalized after 2 re-prompt(s)"
  end

  test "the retry bound counts nudges written under another mode" do
    {pid, _name} = start_agent()

    # Turn one, in the agent's own mode: a silent response is nudged once, then
    # the model speaks — so exactly one nudge is in the transcript.
    MockClient.set_stream_events(silent_response_events())
    MockClient.set_response("First turn's reply.")
    :ok = Agent.chat(pid, "First", nil, nil, true)
    assert_receive {:chat_status, %{status: "idle"}}, 1_000

    # Turn two asks for `plan`, so its own nudge carries a different mode clause.
    # The bound counts nudges, not nudges-under-this-mode: one of the two
    # re-prompts is already spent, so the model gets one more and the turn
    # finalizes. (Counting the headered text instead would see zero, reset the
    # bound, and allow two more.)
    for _ <- 1..3, do: MockClient.set_stream_events(silent_response_events())

    log =
      capture_log(fn ->
        :ok = Agent.chat(pid, "Second", "plan", nil, true)
        assert_receive {:chat_status, %{status: "idle"}}, 1_000
      end)

    assert log =~ "Empty assistant response finalized after 2 re-prompt(s)"

    # allowlist: snapshot — messages
    state = :sys.get_state(pid, 1_000)

    nudges =
      for {:user, %{parts: [%Part.Text{text: text}]}} <- state.chat_state.messages,
          text =~ "empty response",
          do: text

    # One per turn, and the second states the mode its own turn ran in.
    assert length(nudges) == 2
    assert Enum.any?(nudges, &(&1 =~ "[From nest runtime | mode: act]"))
    assert Enum.any?(nudges, &(&1 =~ "[From nest runtime | mode: plan]"))
  end

  test "a normal text response is not nudged" do
    {pid, _name} = start_agent()

    MockClient.set_response("A perfectly normal reply.")

    :ok = Agent.chat(pid, "Analyze the lab")

    assert_receive {:chat_message, {:user, %{index: 1}}}, 1_000
    assert_receive {:chat_message, {:assistant, %{parts: parts}}}, 1_000

    assert Enum.any?(parts, &match?(%Part.Text{text: "A perfectly normal reply."}, &1))

    # No nudge user message appears (the only user message is index 1). The
    # idle broadcast is emitted last, so asserting it first settles the mailbox
    # and a nudge frame would already be here.
    assert_receive {:chat_status, %{status: "idle"}}, 1_000
    refute_received {:chat_message, {:user, %{index: 2}}}
  end
end
