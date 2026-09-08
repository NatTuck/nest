defmodule Nest.Agents.Agent.EmptyResponseRepromptTest do
  @moduledoc """
  Tests for the empty-response re-prompt.

  A model can end a turn having streamed only reasoning
  (`reasoning_content`) and no actual reply text. `ChatTurn` used to
  treat that as a finished answer, leaving the user with a thinking-
  only "reply" and a dead conversation. Now the `ResponseHandler`
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

    assert_receive {:chat_message, {:user, %{index: 1}}}, 500

    # The silent assistant (thinking only) is still shown...
    assert_receive {:chat_message, {:assistant, %{index: 2, parts: [%Part.Thinking{}]}}}, 500

    # ...but the model is asked to actually speak.
    assert_receive {:chat_message, {:user, %{index: 3, parts: [%Part.Text{text: nudge}]}}}, 500
    assert nudge =~ "empty response"

    # And this time it replies with real text.
    assert_receive {:chat_message, {:assistant, %{index: 4, parts: parts}}},
                   500

    assert Enum.any?(parts, &match?(%Part.Text{text: "Here is my actual reply."}, &1))

    assert_receive {:chat_status, %{status: "idle"}}, 500
  end

  test "after the retry cap the turn finalizes with a warning (no infinite loop)" do
    {pid, _name} = start_agent()

    # Three consecutive silent responses: two nudge re-prompts, then
    # give up at the cap.
    for _ <- 1..3, do: MockClient.set_stream_events(silent_response_events())

    log =
      capture_log(fn ->
        :ok = Agent.chat(pid, "Analyze the lab")

        assert_receive {:chat_message, {:user, %{index: 1}}}, 500
        assert_receive {:chat_message, {:assistant, %{index: 2, parts: [%Part.Thinking{}]}}}, 500
        assert_receive {:chat_message, {:user, %{index: 3}}}, 500
        assert_receive {:chat_message, {:assistant, %{index: 4, parts: [%Part.Thinking{}]}}}, 500
        assert_receive {:chat_message, {:user, %{index: 5}}}, 500
        assert_receive {:chat_message, {:assistant, %{index: 6, parts: [%Part.Thinking{}]}}}, 500

        assert_receive {:chat_status, %{status: "idle"}}, 500
      end)

    assert log =~ "Empty assistant response finalized after 2 re-prompt(s)"
  end

  test "a normal text response is not nudged" do
    {pid, _name} = start_agent()

    MockClient.set_response("A perfectly normal reply.")

    :ok = Agent.chat(pid, "Analyze the lab")

    assert_receive {:chat_message, {:user, %{index: 1}}}, 500
    assert_receive {:chat_message, {:assistant, %{parts: parts}}}, 500

    assert Enum.any?(parts, &match?(%Part.Text{text: "A perfectly normal reply."}, &1))

    # No nudge user message appears (the only user message is index 1).
    refute_receive {:chat_message, {:user, %{index: 2}}}, 100

    assert_receive {:chat_status, %{status: "idle"}}, 500
  end
end
