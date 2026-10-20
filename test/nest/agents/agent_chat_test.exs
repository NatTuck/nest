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

      :ok = Agent.chat(pid, "Hello", nil, nil, true)

      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      assert_received {:chat_message, {:user, _}}
      assert_received {:chat_status, %{status: "streaming"}}
      assert_received {:chat_delta, _}
      assert_received {:chat_message, {:assistant, _}}
    end

    test "handles LLM error gracefully" do
      MockClient.set_error("Connection failed")

      {pid, _agent_id} = start_agent()

      log =
        capture_log(fn ->
          :ok = Agent.chat(pid, "Hello", nil, nil, true)

          assert_receive {:chat_status, %{status: "idle"}}, 1_000

          assert_received {:chat_message,
                           {:user,
                            %{
                              index: 1,
                              parts: [%Part.Text{text: "[From user | mode: act]\nHello"}]
                            }}}

          assert_received {:chat_error, _error}
        end)

      assert log =~ "chat:error"
      assert log =~ "Turn.run/2"
      assert log =~ "Connection failed"
    end

    test "user and error assistant messages carry empty api_logs (request logs rebuilt on demand)" do
      # Request logs are no longer attached to user or tool messages
      # during the live flow. The assistant message carries response
      # logs from the external API call. User/tool request logs are
      # rebuilt on demand when the user expands the API logs widget.
      MockClient.set_error("Connection failed")

      {pid, _agent_id} = start_agent()

      capture_log(fn ->
        :ok = Agent.chat(pid, "Hello", nil, nil, true)
        assert_receive {:chat_status, %{status: "idle"}}, 1_000
      end)

      assert_receive {:chat_message, {:user, %{api_logs: user_api_logs}}}, 1_000
      assert_receive {:chat_message, {:assistant, %{api_logs: error_assistant_api_logs}}}, 1_000

      assert user_api_logs == [],
             "user messages should not carry request api_logs after finalization"

      assert error_assistant_api_logs == [],
             "error assistant messages carry no api_logs (the response log was never recorded)"
    end

    test "accumulates delta content and character positions from the streaming response" do
      {pid, _agent_id} = start_agent()

      :ok = Agent.chat(pid, "Hello", nil, nil, true)

      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      # The single-text response produces one text delta. Its content is
      # non-empty (so the containment check below can fail) and its character
      # window is a real span — `is_integer` keeps a `nil`/atom payload from
      # passing `end_pos > start` on Erlang term order.
      assert_received {:chat_delta,
                       %{content: partial_text, chars_start: start, chars_end: end_pos}}

      assert partial_text != ""
      assert is_integer(start)
      assert is_integer(end_pos)
      assert end_pos > start

      # The assistant message broadcast carries the full accumulated
      # content as the externally visible result.
      assert_received {:chat_message, {:assistant, %{parts: parts}}}

      full_text = text_from_parts(parts)
      assert String.contains?(full_text, partial_text)
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
      :sys.replace_state(
        pid,
        fn state ->
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
        end,
        1_000
      )

      MockClient.set_response("Done")

      :ok = Agent.chat(pid, "next question", nil, nil, true)

      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      refute_received {:chat_error, _}

      messages = Agent.get_messages(pid, 1_000)
      tail = Enum.take(messages, -4)

      assert Enum.map(tail, &elem(&1, 0)) == [:user, :assistant, :user, :assistant]

      assert {:assistant, %Assistant{parts: [%Part.Text{text: ack_text}], metadata: metadata}} =
               Enum.at(tail, 1)

      assert ack_text =~ "continuing from here"
      refute Map.has_key?(metadata || %{}, "context_threshold")

      assert {:user, %User{parts: [%Part.Text{text: "[From user | mode: act]\nnext question"}]}} =
               Enum.at(tail, 2)

      assert :ok = Preflight.validate(messages)
    end

    test "a post-compaction user turn appends cleanly without a repair ack" do
      # The compaction commit closes the active segment with the
      # compaction-specific assistant ack, so the next user message lands
      # on an assistant tail and needs no live-path repair bridge. This is
      # the integration half of "an idle agent never ends on a user
      # message": the alternation bridge's text must never appear.
      {pid, _agent_id} = start_agent()

      :sys.replace_state(
        pid,
        fn state ->
          messages = [
            {:system,
             %Nest.Messages.System{
               index: 0,
               parts: [%Part.Text{text: "Test system prompt."}],
               api_logs: []
             }},
            {:user, %User{index: 1, parts: [%Part.Text{text: "previous question"}], api_logs: []}}
          ]

          %{state | chat_state: %{state.chat_state | messages: messages, next_message_index: 2}}
        end,
        1_000
      )

      send_compaction_done(pid, "Summary", nil)
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      messages = Agent.get_messages(pid, 1_000)

      assert {:assistant, %Assistant{parts: [%Part.Text{text: compaction_ack}]}} =
               List.last(messages)

      assert compaction_ack =~ "Compaction complete"
      assert :ok = Preflight.validate(messages)

      MockClient.set_response("Done")
      :ok = Agent.chat(pid, "next question", nil, nil, true)
      assert_receive {:chat_status, %{status: "idle"}}, 1_000

      refute_received {:chat_error, _}

      messages = Agent.get_messages(pid, 1_000)

      assert Enum.map(messages, &elem(&1, 0)) |> Enum.take(-4) ==
               [:user, :assistant, :user, :assistant]

      texts =
        Enum.map(messages, fn {_role, msg} -> text_from_parts(msg.parts) end)

      refute Enum.any?(texts, &(&1 =~ "continuing from here")),
             "the next user turn must not need the alternation bridge ack"

      assert :ok = Preflight.validate(messages)
    end
  end

  describe "vocation in state" do
    test "state.vocation is populated on init when a vocation_id is provided" do
      {:ok, vocation} =
        Vocations.create_vocation(%{
          name: "StateVocation-#{System.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test",
          tools: []
        })

      {pid, _id} = start_agent(%{vocation_id: vocation.id, vocation: vocation})

      # No broadcast carries the full Vocation struct, so the agent's own
      # process is the only place to observe it — through the introspection
      # accessor.
      cached = Agent.get_vocation(pid, 1_000)
      assert cached.id == vocation.id
      assert cached.name == vocation.name
    end
  end
end
