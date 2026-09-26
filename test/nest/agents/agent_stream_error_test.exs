defmodule Nest.Agents.AgentStreamErrorTest do
  @moduledoc """
  Tests for the LLM stream-error path (`LLMStreamHandler.llm_error/2`).

  When a stream fails mid-response — a dropped/incomplete connection or
  an idle timeout — the worker's `on_error` callback sends
  `{:llm_error, _}` to the Agent. The Agent must:

    1. Preserve whatever content had already streamed (as parts of the
       final assistant message) so nothing the model produced is lost.
    2. Append the error text to the same message, tagged
       `metadata: %{"error" => true}` so the UI shows the failure and
       doesn't expect a response log.
    3. Broadcast `chat:error` and transition to `:idle`.
  """
  use Nest.DataCase, async: true

  import Eventually
  import ExUnit.CaptureLog

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  import Nest.Agents.AgentTestHelpers

  describe "llm_error" do
    test "preserves streamed text and appends the error to the final assistant message" do
      # Simulate a dropped connection: some text streamed, then the
      # client reported the stream incomplete (no terminator). Queued
      # before `start_agent/1` so it lands on the per-agent queue.
      MockClient.set_stream_events(
        [{:text, "Halfway through..."}, {:error, {:stream_incomplete, :no_terminator}}],
        auto_done: false
      )

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")

        assert_receive {:chat_status, %{status: "idle"}}, 500

        # The single assistant message carries the partial text AND the
        # error, tagged as an error.
        assert_received {:chat_message,
                         {:assistant, %Assistant{parts: parts, metadata: %{"error" => true}}}}

        assert Enum.any?(parts, &match?(%Part.Text{text: "Halfway through..."}, &1))

        assert Enum.any?(parts, fn
                 %Part.Text{text: text} when is_binary(text) ->
                   text =~ "stream ended unexpectedly"

                 _ ->
                   false
               end)

        assert_received {:chat_error, %{content: content}}
        assert content =~ "stream ended unexpectedly"
      end)

      # The ChatTurn stops asynchronously after `llm_error` idles the
      # agent, so wait for it to clear rather than reading immediately.
      assert eventually(
               fn -> :sys.get_state(pid).live.chat_turn_pid == nil end,
               timeout: 1_000
             )

      state = :sys.get_state(pid)
      assert state.live.status == :idle
    end

    test "an error with no streamed content produces an error-only message" do
      MockClient.set_error({:stream_idle_timeout, 300_000})

      {pid, _agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")
        assert_receive {:chat_status, %{status: "idle"}}, 500

        assert_received {:chat_message,
                         {:assistant,
                          %Assistant{
                            parts: [%Part.Text{text: text}],
                            metadata: %{"error" => true}
                          }}}

        assert text =~ "no output from the model for 300s"
        assert_received {:chat_error, %{content: content}}
        assert content =~ "no output from the model for 300s"
      end)
    end
  end
end
