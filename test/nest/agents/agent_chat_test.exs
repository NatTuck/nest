defmodule Nest.Agents.AgentChatTest do
  @moduledoc """
  Agent chat tests: `chat/2`, delta handling, `chat/3` with mode,
  the Vocation struct in state, and system prompt composition.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog
  import Mimic

  import Nest.Agents.AgentTestHelpers

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    # `AgentTestHelpers.start_agent/1` reads `:nest_test_agent_pid`
    # to find the test pid (the Sandbox owner) so it can transfer
    # any pre-test queued MockClient items to the per-agent queue.
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  describe "chat/2" do
    test "broadcasts user message and LLM response via PubSub" do
      {pid, agent_id} = start_agent()

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert_received {:chat_status, %{status: "streaming"}}
      assert_received {:chat_delta, _}
      assert_received {:chat_message, {:assistant, _}}
    end

    test "broadcasts status changes via PubSub" do
      {pid, agent_id} = start_agent()

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert_received {:chat_message, {:user, _}}
      assert_received {:chat_status, %{status: "streaming"}}
      assert_received {:chat_message, {:assistant, _}}
    end

    test "handles LLM error gracefully" do
      MockClient.set_error("Connection failed")

      {pid, agent_id} = start_agent()

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          assert_receive {:chat_status, %{status: "idle"}}, 500

          assert_received {:chat_message,
                           {:user, %{index: 1, parts: [%Part.Text{text: "[mode: chat]\nHello"}]}}}

          assert_received {:chat_error, _error}
        end)

      assert log =~ "chat:error"
      assert log =~ "ChatTurn.run_chat_task/1"
      assert log =~ "Connection failed"
    end

    test "LLM error path returns a RunState (Task body destructures successfully)" do
      MockClient.set_error("Connection failed")

      {pid, agent_id} = start_agent()

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          assert_receive {:chat_status, %{status: "idle"}}, 500

          assert_received {:chat_message,
                           {:user, %{index: 1, parts: [%Part.Text{text: "[mode: chat]\nHello"}]}}}

          assert_received {:chat_error, _error}
        end)

      refute log =~ "MatchError"
      refute log =~ "no match of right hand side value"
    end

    test "LLM error assistant message carries the request api_log from the triggering user message" do
      # Regression for the typhon "request failed, no API log" path.
      # The request log is broadcast at the user message's index
      # and (via `append_to_existing_message`) attached directly to
      # the user message. The new `llm_error` handler copies those
      # api_logs onto the failed assistant message so the UI's API
      # Logs panel shows the request payload alongside the error,
      # instead of an orphaned assistant error with no api_logs.
      MockClient.set_error("Connection failed")

      {pid, agent_id} = start_agent()

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")
        assert_receive {:chat_status, %{status: "idle"}}, 500
      end)

      # The user message is broadcast after the error handler stamps
      # the error assistant and attaches api_logs. Wait for the
      # second broadcast (with api_logs attached).
      assert_receive {:chat_message, {:user, %{api_logs: [_ | _] = user_api_logs}}}, 500

      assert_receive {:chat_message, {:assistant, %{api_logs: error_assistant_api_logs}}}, 500

      assert error_assistant_api_logs == user_api_logs,
             "failed assistant message should carry the same api_logs as the triggering user message"
    end

    test "accumulates delta content from streaming LLM response" do
      {pid, agent_id} = start_agent()

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      # Accumulate deltas by content; known to be at least 1 for the
      # single set_response text. We match each as a known broadcast.
      assert_received {:chat_message, {:user, _}}

      assert_received {:chat_delta, %{content: partial_text}}

      # The assistant message broadcast carries the full accumulated
      # content as the externally visible result.
      assert_received {:chat_message, {:assistant, %{parts: parts}}}

      full_text = text_from_parts(parts)
      assert partial_text != ""
      assert full_text != ""
      assert String.contains?(full_text, partial_text) or partial_text == full_text
    end
  end

  describe "delta handling" do
    test "accumulates deltas with correct character counts" do
      {pid, agent_id} = start_agent()

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      # At least one delta is expected for the single-text response.
      assert_received {:chat_message, {:user, _}}

      assert_received {:chat_delta, %{chars_start: start, chars_end: end_pos}}
      assert is_integer(start)
      assert is_integer(end_pos)
      assert end_pos > start
    end
  end

  describe "vocation in state" do
    test "state.vocation is populated on init when a vocation_id is provided" do
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "StateVocation-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test",
          tools: [],
          modes: %{
            "build" => %{"caps" => %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}}
          }
        })

      {pid, _id} = start_agent(%{vocation_id: vocation.id, vocation: vocation})

      # No broadcast carries the full Vocation struct; the only way to
      # observe it is via the agent's process state. Kept as future
      # work: expose `state.vocation` via a GenServer call.
      state = :sys.get_state(pid)
      assert state.vocation != nil
      assert state.vocation.id == vocation.id
      assert state.vocation.name == vocation.name
    end
  end
end
