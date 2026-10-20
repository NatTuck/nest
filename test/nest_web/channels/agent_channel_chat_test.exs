defmodule NestWeb.AgentChannelChatTest do
  @moduledoc """
  AgentChannel chat handling tests: `chat:sync`, `chat:status`, the
  `chat:error` event, the `chat:message` status dispositions, and the
  `chat:retry-compaction` / `chat:compact` control handlers.
  """
  use NestWeb.ChannelCase, async: true
  alias Nest.Agents.Agent.Machine
  use NestWeb.AgentChannelTestHelpers

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Supervisor
  alias Nest.LLM.MockClient
  alias Nest.LLM.Preflight
  alias Nest.Messages.Part
  alias Nest.Messages.Streaming

  # `:sys.replace_state/3` with an explicit timeout: OTP's default is 5000 ms,
  # well over both this suite's 500 ms test bound and ExUnit's 2000 ms per-test
  # ceiling, so a wedged server surfaces as the stuck call it is rather than as
  # a test timeout (#21).
  defp replace_state(pid, fun), do: :sys.replace_state(pid, fun, 1_000)

  # Force the agent's observable status (test-only; see `Machine.status_to_machine/2`).
  defp force_status(pid, status) do
    replace_state(pid, fn state ->
      %{
        state
        | live: %{state.live | machine: Machine.status_to_machine(state.live.machine, status)}
      }
    end)
  end

  setup :verify_on_exit!

  describe "handle_in(chat:sync)" do
    test "returns the system message for a new agent", %{socket: socket} do
      # New agent has a single system message at index 0; sync
      # from lastIndex=-1 returns that one. `messageCount` rides the
      # same reply.
      ref = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref, :ok, %{
        "messages" => [system_msg],
        "partial" => nil,
        "status" => "idle",
        "messageCount" => message_count
      }

      assert system_msg["role"] == "system"
      assert message_count == 1
    end

    test "returns messages after lastIndex", %{socket: socket} do
      ref1 = push(socket, "chat:message", %{"content" => "First"})
      assert_reply ref1, :ok, %{}

      assert_push "chat:message", %{"index" => 1, "role" => "user"}, 1_000
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 1_000

      # Fence each turn on its own `idle`: the assistant append happens
      # before the turn finalizes, so syncing before the idle arrives can
      # race a turn that has not landed yet.
      assert_push "chat:status", %{status: "idle"}, 100

      # Sync from current tip: no new messages.
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => 2})
      assert_reply ref_sync, :ok, %{"messages" => [], "partial" => nil, "status" => "idle"}

      ref2 = push(socket, "chat:message", %{"content" => "Second"})
      assert_reply ref2, :ok, %{}

      assert_push "chat:message", %{"index" => 3, "role" => "user"}, 1_000
      assert_push "chat:message", %{"index" => 4, "role" => "assistant"}, 1_000
      assert_push "chat:status", %{status: "idle"}, 100

      # Sync from index 2: messages 3 and 4.
      ref_sync2 = push(socket, "chat:sync", %{"lastIndex" => 2})

      assert_reply ref_sync2, :ok, %{
        "messages" => messages,
        "partial" => _partial,
        "status" => "idle"
      }

      assert length(messages) == 2
    end

    test "returns a nil partial when the agent is not streaming", %{socket: socket} do
      # The fresh-agent case (`partial: nil` before any chat) is the first
      # test in this group; this one pins that a *completed* stream clears
      # the partial again.
      ref = push(socket, "chat:message", %{"content" => "Hello"})
      assert_reply ref, :ok, %{}

      # Wait for completion
      assert_push "chat:message", %{"index" => 2, "role" => "assistant"}, 1_000

      # Consume the turn's idle before syncing: otherwise the
      # `chat:status` push can sit in the socket mailbox ahead of the
      # `chat:sync` reply and `assert_reply` matches the wrong message.
      assert_push "chat:status", %{status: "idle"}, 100

      # Sync after completion - the partial has been cleared.
      ref_sync = push(socket, "chat:sync", %{"lastIndex" => -1})

      assert_reply ref_sync, :ok, %{"partial" => partial}
      assert partial == nil
    end

    test "returns the live partial when streaming", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      # Regression: `partial_payload/2` matched the accumulator's atom
      # `:index`, but `agent.partial` is the already-serialized
      # `Streaming.to_json/1` map (string keys), so `chat:sync` always
      # replied `partial: nil`. The client then cleared its streaming
      # state on every sync, turning a delta gap into an endless sync
      # loop. Seed a live accumulator and assert it round-trips.
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      acc =
        Streaming.new(5)
        |> Streaming.append_text("streaming ")

      replace_state(agent_pid, fn state ->
        %{state | live: %{state.live | streaming_acc: acc}}
      end)

      ref = push(socket, "chat:sync", %{"lastIndex" => 0})

      assert_reply ref, :ok, %{"partial" => partial}

      assert partial["index"] == 5
      assert partial["role"] == "assistant"
      assert partial["content"] == "streaming "
      assert partial["charsEnd"] == 10
    end
  end

  describe "handle_in(chat:status)" do
    test "returns status payload matching init format", %{
      socket: socket,
      agent_id: id
    } do
      # The reply is self-identifying. `messageCount` and `status` on this
      # same reply are pinned by `agent_channel_messaging_test.exs`
      # ("messageCount is highest complete (non-partial) message" and
      # "status transitions idle -> streaming -> idle").
      ref = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref, :ok, %{"name" => status_name, "model" => model}

      assert status_name == id
      assert model["name"] == "qwen3.5-plus"
    end

    test "chat:status reply includes contextLimit, contextLimitSource, and usage",
         %{socket: socket} do
      ref = push(socket, "chat:status", %{"lastIndex" => -1})

      assert_reply ref, :ok, %{
        "contextLimit" => limit,
        "contextLimitSource" => source,
        "usage" => usage
      }

      assert limit == 512_000
      assert source == "config"
      # `context_input_tokens` is the system prompt's estimated
      # size — non-zero so the chip displays a meaningful fill
      # rate from page load.
      assert usage == %{
               input_tokens: 0,
               cache_read_input_tokens: 0,
               cache_creation_input_tokens: 0,
               context_input_tokens: usage.context_input_tokens,
               working_budget: 409_600,
               projected_context_input_tokens: nil,
               last_output: 0,
               output_tokens: 0,
               total_input_tokens: 0,
               total_cache_read_input_tokens: 0,
               total_cache_creation_input_tokens: 0,
               total_tokens: 0,
               reasoning_tokens: 0
             }

      assert usage.context_input_tokens > 0
    end

    test "returns error when agent not found", %{socket: _socket} do
      # Connect a fresh socket with a valid token, then try to
      # join a topic that doesn't exist — `Agents.get_agent/1`
      # returns `:not_found`, the channel rejects the join.
      token = Process.get(:agent_test_token)
      {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})

      assert {:error, %{"reason" => "agent not found"}} =
               subscribe_and_join(
                 connected,
                 NestWeb.AgentChannel,
                 "agent:1:nonexistent"
               )
    end
  end

  describe "chat:error event" do
    test "broadcasts error with index and content", %{socket: socket} do
      # Mock the LLM to fail. `Client.run/2` always returns
      # `{:ok, stream}` per the behaviour; errors are surfaced as
      # `{:error, _}` events inside the stream, which the agent
      # captures in the reducer's `error` field and routes to
      # `handle_failed_response/3`.
      MockClient.set_error("model unavailable")

      log =
        capture_log(fn ->
          ref = push(socket, "chat:message", %{"content" => "Hello"})
          assert_reply ref, :ok, %{}

          assert_push "chat:error", payload, 1_000
          assert payload["index"] == 2
          assert payload["content"] =~ "unavailable" or payload["content"] =~ "error"

          # The error assistant append is followed by the agent's
          # transition back to idle; wait for it so the turn is done
          # before the test exits.
          assert_push "chat:status", %{status: "idle"}, 100
        end)

      # Verify the error was logged with the correct message
      assert log =~ "chat:error"
      assert log =~ "Turn.run/2"
      assert log =~ "model unavailable"
    end
  end

  describe "handle_in(chat:message) status dispositions" do
    test "queues chat:message when the agent is :compacting", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      force_status(agent_pid, :compacting)

      ref = push(socket, "chat:message", %{"content" => "during compaction"})

      # A busy agent queues the message for its next turn boundary; the
      # channel no longer rejects `:compacting`.
      assert_reply ref, :ok, %{}

      info = Nest.Agents.Agent.get_public_info(agent_pid, 1_000)
      assert [%{"content" => "during compaction", "kind" => "user"}] = info.pending_messages
      assert info.status == :compacting

      # The `:compacting` status was fabricated for the disposition check
      # (there is no real turn). Restore idle so the teardown's
      # zero-in-flight-agents assertion holds.
      replace_state(agent_pid, fn state ->
        %{
          state
          | live: %{
              state.live
              | inbox: [],
                machine: Machine.status_to_machine(state.live.machine, :idle)
            }
        }
      end)
    end

    test "rejects chat:message when the agent is :compaction_failed", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      force_status(agent_pid, :compaction_failed)

      ref = push(socket, "chat:message", %{"content" => "after failure"})

      assert_reply ref, :error, %{"reason" => "agent_status_compaction_failed"}
    end
  end

  describe "handle_in(chat:retry-compaction)" do
    test "forwards to Agents.retry_compaction/1", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      # Retry resumes from `:compaction_failed`. A held user message
      # without the mid-turn entry it normally accompanies fabricates a
      # post-compaction resume of `[system, summary_user, user]` — two
      # user roles in a row. The append-time pairing bridge now inserts
      # the assistant acknowledgement before the held user message, so
      # the resume is wire-valid and the turn runs to completion instead
      # of being refused by the send guard. This test pins the
      # *forwarding* (the `:compacting` transition) and that the resume
      # completes.
      replace_state(agent_pid, fn state ->
        %{
          state
          | live: %{
              state.live
              | machine: %{
                  Machine.status_to_machine(
                    state.live.machine,
                    :compaction_failed
                  )
                  | pending_user_message: {"Hello", "chat"}
                }
            }
        }
      end)

      # The send guard used to reject this resume at error level; with the
      # append-time bridge repairing it, no warning/error is expected.
      capture_log(fn ->
        ref = push(socket, "chat:retry-compaction", %{})

        assert_reply ref, :ok, %{}

        assert_receive {:chat_status, %{status: "compacting"}}, 1_000

        # Finish the retried compaction so the agent is idle at test
        # end (the teardown asserts zero in-flight agents).
        assert_receive {:chat_status, %{status: "idle"}}, 1_000
      end)

      # The held user message was appended after the compaction summary
      # (wire role `user`); the bridge inserted an assistant ack so the
      # resumed list is wire-valid and the turn actually ran. The held row is
      # the legacy `{content, mode}` shape, which is built with no sender — so
      # no header — and is a hand-built fixture's shape, not a production one.
      messages = Nest.Agents.Agent.get_messages(agent_pid, 1_000)

      assert :ok = Preflight.validate(messages)

      assert Enum.any?(messages, fn
               {:user, %{parts: parts}} ->
                 Enum.any?(parts || [], &match?(%Part.Text{text: "Hello"}, &1))

               _ ->
                 false
             end)
    end
  end

  describe "handle_in(chat:compact)" do
    test "stages a compaction for an idle agent and forwards the focus", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      # Fail the compactor's LLM call so the machine parks in
      # `:compaction_failed` right after staging. That is a deterministic
      # sync point: a failed compaction keeps the focus for the retry, so
      # the state is stable there. Asserting right after the reply would
      # instead race the compactor's completion, which legitimately clears
      # the focus on the way back to idle.
      MockClient.set_error("boom")

      log =
        capture_log(fn ->
          ref = push(socket, "chat:compact", %{"focus" => "keep the API decisions"})

          assert_reply ref, :ok, %{}

          assert_receive {:chat_status, %{status: "compacting"}}, 1_000
          assert_receive {:chat_status, %{status: "compaction_failed"}}, 1_000
        end)

      assert log =~ "Compaction failed"

      # The channel read `payload["focus"]` and threaded it through
      # `Agents.compact/3` → `Agent.compact/2` onto the machine's working
      # set synchronously (before the reply).
      assert Nest.Agents.Agent.get_work(agent_pid, 1_000).focus == "keep the API decisions"

      # Retrying re-renders the same focus; the compactor completes
      # (MockClient's random-text fallback) and the agent returns to idle.
      retry_ref = push(socket, "chat:retry-compaction", %{})

      assert_reply retry_ref, :ok, %{}
      assert_receive {:chat_status, %{status: "idle"}}, 1_000
    end

    test "rejects a compaction while the agent is busy", %{
      socket: socket,
      agent_id: id,
      space_id: space_id
    } do
      {:ok, agent_pid} = Supervisor.get_agent(space_id, id)

      force_status(agent_pid, :compacting)

      ref = push(socket, "chat:compact", %{})

      assert_reply ref, :error, %{"reason" => "agent_status_compacting"}

      # The `:compacting` status was fabricated for the rejection check
      # (there is no real turn). Restore idle so the teardown's
      # zero-in-flight-agents assertion holds.
      force_status(agent_pid, :idle)
    end
  end
end
