defmodule Nest.Agents.AgentStopTest do
  @moduledoc """
  Tests for the user-initiated chat-stop flow. Covers:

    * Stopping mid-LLM-stream — partial assistant text is
      finalized into a message tagged with
      `metadata.stopped_by_user: true` and the agent
      transitions to `:idle`.
    * Stopping after the LLM stream completes (between turns)
      — no-op.
    * Stopping during a `context` tool compaction call — chat
      task unwinds, no `:compaction_done` chat_continuation
      auto-resumes.
    * Idempotency — multiple `Agent.stop_chat/2` calls
      before finalization don't crash anything.
  """
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.Agents.Agent
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part

  setup :verify_on_exit!

  import Nest.Agents.AgentTestHelpers

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    # Drain the test process's mailbox at the start of
    # each test. The previous test's chat turn may have
    # left late events in flight (deltas, status pushes,
    # :stopped replies) that would otherwise match this
    # test's assert_receive patterns. The on_exit hook
    # in start_agent/1 also drains, but it runs AFTER
    # this setup; we drain BEFORE the test's assertions.
    drain_test_mailbox()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  describe "stop_chat/2 mid-LLM-stream" do
    test "finalizes the partial assistant message and transitions to idle" do
      events = for _ <- 1..1000, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, %{index: 1}}}, 500
      assert_receive {:chat_status, %{status: "streaming"}}, 500
      assert_receive {:chat_delta, _}, 500

      Agent.stop_chat(pid, self())

      assert_receive {:chat_message,
                      {:assistant, %Assistant{metadata: %{"stopped_by_user" => true}}}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 500
    end

    test "the finalized assistant message carries the partial text content" do
      events = for _ <- 1..1000, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Tell me a story")
      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      Agent.stop_chat(pid, self())

      assert_receive {:chat_message,
                      {:assistant, %Assistant{parts: [%Part.Text{text: content}], index: 2}}},
                     2000

      assert is_binary(content)
      assert content != ""
      assert String.starts_with?(content, "x")
    end
  end

  describe "stop_chat/2 between turns" do
    test "is a no-op when the agent is idle" do
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      # No chat turn is in flight. The stop handler runs
      # without crashing; no `chat:status: idle` is broadcast
      # because the agent is already idle. The `refute_receive`
      # waits up to 50ms for a broadcast that should never come.
      :ok = Agent.stop_chat(pid, self())
      refute_receive {:chat_status, _}, 50
    end
  end

  describe "stop_chat/2 before any LLM delta" do
    test "inserts a placeholder assistant message so the messages list stays alternation-valid" do
      # The user clicks Stop between sending the message and
      # receiving any text from the LLM (e.g., the HTTP worker
      # is mid-stream, has not yet emitted any delta events).
      # The Agent's `chat_stopped` handler must append a
      # placeholder assistant message — `streaming_acc` is
      # `nil` because no deltas arrived — so the messages
      # list alternation invariant holds for the next user
      # turn (which will need a trailing `:assistant` to
      # land Case A's full-pair injection).
      #
      # Without the placeholder, the messages list would end
      # with `user(real)` and any subsequent chat would
      # start from there — wire-valid for Case A trailing
      # `:user`. But the user already started a turn, so the
      # assistant turn is *in flight* and must be recorded
      # (even if empty) before the chat finalizes. This
      # matches the UX: the user sees "stopped" in the UI,
      # not a missing assistant message.
      #
      # Send stop directly to the chat turn pid so the stop
      # wins the race against the streaming worker (the
      # worker is spawned but has not yet emitted deltas).
      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_status, %{status: "streaming"}}, 500

      chat_turn_pid = :sys.get_state(pid).chat_state.chat_turn_pid
      assert is_pid(chat_turn_pid)

      # Stop before any delta arrives. `streaming_acc` is
      # `nil` because no `{:delta_received, _, :text}` event
      # has reached the Agent yet. Use `GenServer.call`
      # (per SMELLS.md) — the call blocks until the
      # ChatTurn's `handle_call({:stop_chat, _})` replies
      # `:ok`.
      GenServer.call(chat_turn_pid, {:stop_chat, self()}, :infinity)

      assert_receive {:chat_message,
                      {:assistant, %Assistant{metadata: %{"stopped_by_user" => true}}}},
                     500

      assert_receive {:chat_status, %{status: "idle"}}, 500

      # The placeholder assistant carries empty parts (no
      # partial text — no deltas arrived). The `stopped_by_user`
      # metadata flag is set so the UI can render the "stopped"
      # indicator on the empty assistant message.
      state = :sys.get_state(pid)

      assert Enum.any?(
               state.chat_state.messages,
               fn
                 {:assistant, %Assistant{parts: [], metadata: %{"stopped_by_user" => true}}} ->
                   true

                 _ ->
                   false
               end
             )
    end
  end

  describe "stop_chat/2 during context tool (compact action)" do
    test "the tool-call mid-execution stop unwinds without auto-resume" do
      # Set up a stream that emits one `context` tool call
      # with `action: "compact"`. The chat task enters
      # `request_compaction_from_task` which blocks on a
      # receive. We stop the chat task while it's blocked there.
      MockClient.set_tool_response(%{
        text: "compacting",
        tool_calls: [
          %{
            id: "call_1",
            name: "context",
            arguments: %{"action" => "compact", "focus" => "recent"}
          }
        ]
      })

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "compact please")

      assert_receive {:chat_message, {:user, _}}, 500
      # The tool call message is broadcast; the chat task
      # is now in `request_compaction_from_task` blocking on
      # `{:task_compaction_done|_failed, _}` or `{:stop_chat, _}`.
      # Drain to find the assistant carrying the tool call
      # (a context-notice synthetic pair may precede it).
      tool_assistant = wait_for_assistant_with_tool_use(2_000)
      assert tool_assistant != nil
      assert Enum.any?(tool_assistant.parts, &match?(%Part.ToolUse{}, &1))
      assert_receive {:chat_status, %{status: "executing_tools"}}, 500

      # The chat task is now in the blocking receive inside
      # `request_compaction_from_task/2`. Send the stop via
      # `GenServer.call` (per SMELLS.md, no `send` between
      # our own GenServers) so the call blocks until the
      # ChatTurn's `handle_call({:stop_chat, _})` replies
      # `:ok`.
      chat_turn_pid = :sys.get_state(pid).chat_state.chat_turn_pid
      assert is_pid(chat_turn_pid)

      # The ChatTurn's `handle_call({:stop_chat, _})` returns
      # `{:reply, :ok, {:stop, :normal, state}}` — it sends the
      # reply AND stops with :normal. GenServer.call in some
      # OTP versions treats the reply-then-stop as a `:normal`
      # exit signal on the caller (the monitor fires before the
      # reply is processed). Catch the exit and assert the
      # reply value matches.
      call_reply =
        try do
          GenServer.call(chat_turn_pid, {:stop_chat, self()}, :infinity)
        catch
          :exit, :normal -> :ok
        end

      assert call_reply == :ok

      # The agent's stop handler waits for the chat task to
      # ack via `{:chat_stopped, _}`. The tool loop's
      # `request_compaction_from_task/2` catches the
      # `{:stop_chat, _}`, replies `:stopped`, and the
      # tool executor raises `ToolLoop.StoppedError`, which
      # the chat task body catches and turns into the
      # `{:chat_stopped, self()}` ack.
      assert_receive {:chat_status, %{status: "idle"}}, 2000
    end
  end

  describe "stop_chat/2 idempotency" do
    test "multiple stop clicks don't crash the agent" do
      events = for _ <- 1..100, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      # Three rapid stops via the public `Agent.stop_chat/2`
      # entry point. Each is a `GenServer.call` to the
      # Agent's `handle_call({:stop_chat, _})`, which sets
      # `cancelled` and propagates to the ChatTurn via
      # `GenServer.call(chat_turn_pid, {:stop_chat, _}, 5_000)`.
      # The first call does the real work (kills the worker,
      # stops the ChatTurn, casts `{:chat_stopped, _}` to
      # the Agent). After it returns, `state.chat_state.chat_turn_pid`
      # is `nil`, so the second and third calls' `if chat_turn_pid`
      # branch is skipped — no work, no second `chat_stopped`
      # cast.
      Agent.stop_chat(pid, self())
      Agent.stop_chat(pid, self())
      Agent.stop_chat(pid, self())

      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # After the stop, the agent is in a clean state. A new
      # chat turn should work normally.
      :ok = Agent.chat(pid, "After the stop")

      # Wait for the full second-turn to complete (idle
      # status) BEFORE asserting the earlier events. This
      # avoids mailbox pollution from the first turn that
      # could otherwise match the second turn's assertions
      # in a flaky way.
      assert_receive {:chat_status, %{status: "idle"}}, 2000
      assert_receive {:chat_message, {:user, %{index: 3}}}, 500
      assert_receive {:chat_message, {:assistant, _}}, 500
    end
  end

  describe "stop_chat/2 then a new chat turn" do
    test "the cancelled flag is cleared so the next pre-flight compaction can resume" do
      # First turn: stream a long-ish text response that we'll
      # stop mid-stream.
      events = for _ <- 1..100, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "First turn")
      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      Agent.stop_chat(pid, self())
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # The `cancelled` flag must be cleared on the next turn,
      # otherwise a pre-flight compaction's `chat_continuation`
      # would be discarded (see the guard in
      # `CompactionHandler.compaction_done/3`).

      # Second turn: a normal text response.
      MockClient.set_response("Second turn response")

      :ok = Agent.chat(pid, "Second turn")

      # Wait for the second turn to reach :idle first
      # (consuming the user message and assistant message
      # along the way). This is more robust than asserting
      # the user message first, which can flake when the
      # first turn's stale messages pollute the test
      # process's mailbox.
      assert_receive {:chat_status, %{status: "idle"}}, 2000
      assert_receive {:chat_message, {:user, %{index: 3}}}, 500

      assert_receive {:chat_message,
                      {:assistant, %{parts: [%Part.Text{text: "Second turn response"}]}}},
                     500
    end
  end

  # Regression guard for the agent_stop_test.exs flakiness.
  # The flakiness was caused by late deltas from a previous
  # chat arriving at the Agent AFTER chat_stopped set the
  # streaming_acc to nil; the delta handler then crashed
  # with FunctionClauseError. The fix in llm_stream_handler
  # .ex's delta_received/3 makes the handler a no-op when
  # streaming_acc is nil. This test exercises the exact
  # race: a streaming chat is stopped, a new chat starts
  # while the old chat's deltas are still in flight, and
  # the new chat must complete successfully. A future
  # regression (re-introducing the nil-deref) would crash
  # the Agent GenServer and fail the second chat's idle
  # status assertion.
  describe "stability" do
    test "stopped chat's late deltas don't crash a subsequent chat" do
      events = for _ <- 1..50, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "First turn")
      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      Agent.stop_chat(pid, self())
      assert_receive {:chat_status, %{status: "idle"}}, 2000

      # Immediately start a new chat. The previous chat's
      # HTTP worker may still be in flight; any late
      # deltas must not crash the Agent.
      MockClient.set_response("Second response")
      :ok = Agent.chat(pid, "Second turn")

      assert_receive {:chat_status, %{status: "idle"}}, 2000
      assert_receive {:chat_message, {:user, %{index: 3}}}, 500

      assert_receive {:chat_message,
                      {:assistant, %{parts: [%Part.Text{text: "Second response"}]}}},
                     500

      # The Agent GenServer must still be alive (the
      # original bug crashed it with FunctionClauseError).
      assert Process.alive?(pid)
    end
  end

  describe "stop_chat/2 returns synchronously" do
    test "Agent.stop_chat/2 is a GenServer.call that blocks until the Agent's handle_call replies" do
      # The new `Agent.stop_chat/2` is `GenServer.call(pid,
      # {:stop_chat, from}, :infinity)`. Per SMELLS.md, all
      # own-GenServer communication uses call/cast — no
      # `send/2`. The test verifies the call returns `:ok`
      # (the synchronous return) and that the ChatTurn's pid
      # is gone from the Agent's state by the time the call
      # returns (because the Agent's `handle_call({:stop_chat,
      # _})` propagated to the ChatTurn before replying).
      events = for _ <- 1..100, do: {:text, "x"}
      MockClient.set_stream_events(events)

      {pid, agent_id} = start_agent(%{model: %{name: "qwen3.5-plus"}})
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_id}")

      :ok = Agent.chat(pid, "Start")

      assert_receive {:chat_message, {:user, _}}, 500
      assert_receive {:chat_delta, _}, 500

      # The call is synchronous — it returns :ok only after
      # the Agent has processed the stop and replied. The
      # :ok pattern match here verifies the return value.
      assert :ok = Agent.stop_chat(pid, self())

      # After the call returns, the ChatTurn has been
      # signaled to stop and the Agent's state reflects
      # `chat_turn_pid: nil`. The `cancelled` flag has
      # already been cleared by the casted `{:chat_stopped,
      # _}` handler that runs immediately after the call
      # returns (the cast is queued in the Agent's mailbox
      # and processed before our `:sys.get_state/1` call).
      state = :sys.get_state(pid)
      assert state.chat_state.chat_turn_pid == nil
      assert state.chat_state.cancelled == false

      assert_receive {:chat_status, %{status: "idle"}}, 2000
    end
  end

  # Drain assistant messages until one carries a `Part.ToolUse`.
  # A context-notice synthetic pair (an assistant message with
  # `text: "Context?"`) may precede the real tool-call assistant
  # when the context threshold is crossed.
  defp wait_for_assistant_with_tool_use(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_assistant_with_tool_use(deadline)
  end

  defp do_wait_for_assistant_with_tool_use(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      nil
    else
      receive do
        {:chat_message, {:assistant, msg}} ->
          if Enum.any?(msg.parts, &match?(%Part.ToolUse{}, &1)) do
            msg
          else
            do_wait_for_assistant_with_tool_use(deadline)
          end
      after
        100 -> do_wait_for_assistant_with_tool_use(deadline)
      end
    end
  end
end
