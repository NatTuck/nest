defmodule Nest.Agents.Agent.MaxTokensContinuationTest do
  @moduledoc """
  Tests for continuing a response truncated by the output token limit.

  A model that runs out of output tokens mid-answer stops with
  `stop_reason` `"max_tokens"` (Anthropic) or `"length"` (OpenAI). That
  is not a finished reply: `Machine.Response` appends a "keep going"
  user nudge and re-asks, bounded by `@max_truncation_retries`, so the
  answer is completed instead of dead-ending.
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

  test "a truncated response is continued with a keep-going nudge" do
    {pid, _name} = start_agent()

    MockClient.set_stream_events([
      {:text, "The first half of the answer"},
      {:finish_reason, "max_tokens"}
    ])

    MockClient.set_response("...and the second half.")

    :ok = Agent.chat(pid, "Explain the thing")

    assert_receive {:chat_message, {:user, %{index: 1}}}, 500

    assert_receive {:chat_message, {:assistant, %{index: 2, parts: parts}}}, 500
    assert Enum.any?(parts, &match?(%Part.Text{text: "The first half of the answer"}, &1))

    assert_receive {:chat_message, {:user, %{index: 3, parts: [%Part.Text{text: nudge}]}}}, 500
    assert nudge =~ "Keep going"

    assert_receive {:chat_message, {:assistant, %{index: 4, parts: parts2}}}, 500
    assert Enum.any?(parts2, &match?(%Part.Text{text: "...and the second half."}, &1))

    assert_receive {:chat_status, %{status: "idle"}}, 500
  end

  test "truncation takes precedence over the empty-response nudge" do
    {pid, _name} = start_agent()

    # Thinking only, no text — normally the empty-response path. The
    # `length` stop reason means the model was cut off mid-reasoning, so
    # the continuation nudge must win.
    MockClient.set_stream_events([
      {:thinking, "Reasoning right up to the token limit..."},
      {:finish_reason, "length"}
    ])

    MockClient.set_response("Here is the real reply.")

    :ok = Agent.chat(pid, "Analyze the lab")

    assert_receive {:chat_message, {:user, %{index: 1}}}, 500
    assert_receive {:chat_message, {:assistant, %{index: 2, parts: [%Part.Thinking{}]}}}, 500

    assert_receive {:chat_message, {:user, %{index: 3, parts: [%Part.Text{text: nudge}]}}}, 500
    assert nudge =~ "Keep going"
    refute nudge =~ "empty response"

    assert_receive {:chat_message, {:assistant, %{index: 4, parts: parts}}}, 500
    assert Enum.any?(parts, &match?(%Part.Text{text: "Here is the real reply."}, &1))

    assert_receive {:chat_status, %{status: "idle"}}, 500
  end

  test "after the retry cap the truncated turn finalizes with a warning" do
    {pid, _name} = start_agent()

    # Three consecutive truncated responses: two keep-going nudges, then
    # give up at the cap.
    for _ <- 1..3 do
      MockClient.set_stream_events([
        {:text, "still going"},
        {:finish_reason, "max_tokens"}
      ])
    end

    log =
      capture_log(fn ->
        :ok = Agent.chat(pid, "Keep writing")

        assert_receive {:chat_message, {:user, %{index: 1}}}, 500
        assert_receive {:chat_message, {:assistant, %{index: 2}}}, 500
        assert_receive {:chat_message, {:user, %{index: 3}}}, 500
        assert_receive {:chat_message, {:assistant, %{index: 4}}}, 500
        assert_receive {:chat_message, {:user, %{index: 5}}}, 500
        assert_receive {:chat_message, {:assistant, %{index: 6}}}, 500

        assert_receive {:chat_status, %{status: "idle"}}, 500
      end)

    assert log =~ "Truncated assistant response finalized after 2 keep-going re-prompt(s)"
  end
end
