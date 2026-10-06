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
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User
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
      {pid, _agent_id} = start_agent()

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert_received {:chat_status, %{status: "streaming"}}
      assert_received {:chat_delta, _}
      assert_received {:chat_message, {:assistant, _}}
    end

    test "broadcasts status changes via PubSub" do
      {pid, _agent_id} = start_agent()

      :ok = Agent.chat(pid, "Hello")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      assert_received {:chat_message, {:user, _}}
      assert_received {:chat_status, %{status: "streaming"}}
      assert_received {:chat_message, {:assistant, _}}
    end

    test "handles LLM error gracefully" do
      MockClient.set_error("Connection failed")

      {pid, _agent_id} = start_agent()

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello")

          assert_receive {:chat_status, %{status: "idle"}}, 500

          assert_received {:chat_message,
                           {:user, %{index: 1, parts: [%Part.Text{text: "[mode: chat]\nHello"}]}}}

          assert_received {:chat_error, _error}
        end)

      assert log =~ "chat:error"
      assert log =~ "Turn.run/2"
      assert log =~ "Connection failed"
    end

    test "LLM error path returns a RunState (Task body destructures successfully)" do
      MockClient.set_error("Connection failed")

      {pid, _agent_id} = start_agent()

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

    test "user and error assistant messages carry empty api_logs (request logs rebuilt on demand)" do
      # Request logs are no longer attached to user or tool messages
      # during the live flow. The assistant message carries response
      # logs from the external API call. User/tool request logs are
      # rebuilt on demand when the user expands the API logs widget.
      MockClient.set_error("Connection failed")

      {pid, _agent_id} = start_agent()

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello")
        assert_receive {:chat_status, %{status: "idle"}}, 500
      end)

      assert_receive {:chat_message, {:user, %{api_logs: user_api_logs}}}, 500
      assert_receive {:chat_message, {:assistant, %{api_logs: error_assistant_api_logs}}}, 500

      assert user_api_logs == [],
             "user messages should not carry request api_logs after finalization"

      assert error_assistant_api_logs == [],
             "error assistant messages carry no api_logs (the response log was never recorded)"
    end

    test "accumulates delta content from streaming LLM response" do
      {pid, _agent_id} = start_agent()

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

    test "a user message after a user tail is bridged and delivered, not dropped" do
      # Regression for the "send user message after user message" bug.
      # An idle agent whose active list ends on a `user` message (e.g. a
      # crash between the user append and the first assistant delta) must
      # have the canonical assistant bridge inserted before the next user
      # message, so alternation holds and the message is delivered. Before
      # the fix the turn-opening append was classified as a live append,
      # `Repair.classify_live/2` refused the consecutive-user shape, and
      # the turn died with `chat:error`, dropping the user's message.
      {pid, _agent_id} = start_agent()

      # High `context_limit` so no context notice fires: the only possible
      # source of the bridge is the sequence repair, not a threshold.
      :sys.replace_state(pid, fn state ->
        messages = [
          {:system,
           %Nest.Messages.System{
             index: 0,
             parts: [%Part.Text{text: "Test system prompt."}],
             api_logs: []
           }},
          {:user, %User{index: 1, parts: [%Part.Text{text: "previous question"}], api_logs: []}}
        ]

        %{
          state
          | chat_state: %{state.chat_state | messages: messages, next_message_index: 2},
            llm_metrics: %{state.llm_metrics | context_limit: 200_000}
        }
      end)

      MockClient.set_response("Done")

      :ok = Agent.chat(pid, "next question")

      assert_receive {:chat_status, %{status: "idle"}}, 500

      refute_received {:chat_error, _}

      state = :sys.get_state(pid)
      tail = Enum.take(state.chat_state.messages, -4)

      assert Enum.map(tail, &elem(&1, 0)) == [:user, :assistant, :user, :assistant]

      assert {:assistant, %Assistant{parts: [%Part.Text{text: ack_text}], metadata: metadata}} =
               Enum.at(tail, 1)

      assert ack_text =~ "interrupted"
      refute Map.has_key?(metadata || %{}, "context_threshold")

      assert {:user, %User{parts: [%Part.Text{text: "[mode: chat]\nnext question"}]}} =
               Enum.at(tail, 2)

      assert :ok = Preflight.validate(state.chat_state.messages)
    end
  end

  describe "delta handling" do
    test "accumulates deltas with correct character counts" do
      {pid, _agent_id} = start_agent()

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
