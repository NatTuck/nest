defmodule Nest.Agents.AgentCompactionChatContinuationTest do
  @moduledoc """
  Regression tests for the `chat_continuation` path of the
  compaction handler. This path was the one that crashed the
  `overall-crawdad` agent in production: after a compaction
  completes, the handler calls `ChatPipeline.resume_after_compaction/3`
  to append the user message that triggered the compaction and
  spawn the next chat turn.

  Pre-fix, two bugs collided here:

  1. `ChatPipeline.build_user_message/3` returned a 2-tuple of
     `{:user, _}` tuples instead of a single tuple, so
     `__append_message__/2`'s `put_message_index/2` raised
     `FunctionClauseError`. The `handle_chat/3` caller
     destructured the result correctly; `resume_after_compaction/3`
     did not.

  2. `CompactionLifecycle.swap_messages/5` re-assigned the new
     compacted state's indices but did NOT bump
     `state.chat_state.next_message_index` past the new state.
     The post-compaction user message was therefore stamped at
     the pre-swap `next_message_index`, which collided with (or
     sat below) the new compacted state's first row.

  This file pins the fixed contract:

    * The user message is stamped at exactly
      `state.chat_state.next_message_index` (which is now
      `marker_index + length(new_state) + 1` post-swap, not the
      pre-swap value).
    * `state.chat_state.next_message_index` advances by 1 after
      the append.
    * The new compacted state's indices (set by
      `regenerate_for_compaction/2`) are preserved through the
      resume (no re-numbering that would shift the assistant
      slot or break `streaming_acc`).

  `async: false` for the same reason as the other compaction
  tests (sandbox connection walks `$callers` at the agent
  boundary, async tests lose ownership).
  """
  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Init
  alias Nest.LLM.MockClient
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  defp programmer_vocation_id do
    {:ok, vocation} =
      Vocations.create_vocation(%{
        name: "Chat Continuation Test (#{Elixir.System.unique_integer([:positive])})",
        description: "For resume_after_compaction regression tests",
        system_prompt: "Test prompt.",
        tools: ["read_file", "write_file", "edit", "shell_cmd", "context"],
        modes: %{
          "build" => %{
            "description" => "Test mode",
            "caps" => %{
              "net" => true,
              "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
            }
          }
        }
      })

    vocation.id
  end

  # Three compactor messages: leading system with the
  # encoded summary, then a user message, then an assistant
  # reply. The handler extracts the summary from the
  # leading system, re-renders it as a user message at
  # position 1, and re-numbers the rest from position 3.
  defp compactor_output do
    [
      {:system,
       %System{
         index: 1,
         parts: [%Part.Text{text: "[Summary of earlier conversation]:\n\nkey facts"}]
       }},
      {:user, %User{index: 2, parts: [%Part.Text{text: "Next"}], api_logs: []}}
    ]
  end

  describe "resume_after_compaction/3 (regression: optimistic/server race)" do
    test "stamps the resumed user message at next_message_index (Bug 1 + Bug 4)" do
      # Pre-fix, `build_user_message/3` returned a 2-tuple, and
      # `next_message_index` was the pre-swap value. Both crashed
      # here. Post-fix, the user message lands at the post-swap
      # `next_message_index` (= marker_index + 1 + 1 + 1 = 3 in
      # this setup: marker_index=1, fresh_system=2, summary=3,
      # no other renumbered output, so next_message_index=3).
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation_id
        })

      # Pre-seed next_message_index so marker_index is well-defined.
      # Also pre-seed `pending_user_message` (per TODO 4 in
      # `notes/extract-compaction-and-resumable-chat-turn.md`):
      # `ChatPipeline.resume_with_pending/1` reads the user message
      # from this field rather than from the legacy
      # `{:chat_continuation, {content, mode}}` tuple.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | next_message_index: 1,
                pending_user_message: {"What was the last question?", "build"}
            }
        }
      end)

      send(
        pid,
        {:compaction_done, compactor_output(), {:chat_continuation, :pending}}
      )

      # The handler runs the swap and then calls
      # `ChatPipeline.resume_after_compaction/3`, which calls
      # `__append_message__/2` on the user message. The pre-fix
      # `put_message_index/2` FunctionClauseError would crash
      # the GenServer here; the test would observe a DOWN
      # rather than a state update.
      state_after = :sys.get_state(pid, 500)

      # Find the last user message in the post-swap state.
      # The handler appends the resumed user message via
      # `__append_message__/2` AFTER the swap, so it lives at
      # the tail of `state.chat_state.messages`.
      last_user =
        state_after.chat_state.messages
        |> Enum.reverse()
        |> Enum.find(&match?({:user, _}, &1))

      assert last_user != nil, "expected a user message in state.chat_state.messages"

      {_, %User{index: user_index}} = last_user
      # The compactor output has 2 messages, so
      # `regenerate_for_compaction/2` produces 3 messages
      # (fresh_system at 2, summary_user at 3, compactor user
      # at 4). Post-swap next_message_index = marker_index (1)
      # + length(new_state) (3) + 1 = 5. The resumed user
      # message is stamped at 5, then next_message_index
      # advances to 6.
      assert user_index == 5,
             "expected user message at index 5, got #{user_index}"

      # next_message_index advanced by 1 after the append.
      assert state_after.chat_state.next_message_index == 6

      Agent.terminate(pid)
    end

    test "compaction marker is at marker_index, not marker_index + 1 (Bug 2)" do
      # Regression for the marker-index off-by-one: the
      # agent's `chat_state.history` ends with a `{:compaction, _}`
      # marker whose `.index` field is the pre-swap
      # `next_message_index` (= 1 in this setup). Pre-fix the
      # DB-side `archive_and_compact/4` tried to insert the
      # marker at `last_index + 1 = 2` and collided with the
      # fresh system message that `regenerate_for_compaction/2`
      # had already persisted at index 2.
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation_id
        })

      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | next_message_index: 1}}
      end)

      send(
        pid,
        {:compaction_done, compactor_output(), {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      state_after = :sys.get_state(pid)

      # The compaction marker is the last entry in history.
      [{:compaction, marker} | _] = Enum.reverse(state_after.chat_state.history)

      assert marker.index == 1,
             "expected marker index == 1, got #{marker.index}"

      # And the new compacted state's first row is the fresh
      # system at marker_index + 1.
      [first | _] = state_after.chat_state.messages
      assert {_, %{index: 2}} = first

      Agent.terminate(pid)
    end

    test "swap_messages bumps next_message_index past the new compacted state (Bug 4)" do
      # Without the bump, the resumed user message in the
      # first test would be stamped at the pre-swap value (1),
      # below the fresh system (2). With the bump, the post-swap
      # next_message_index is one past the new compacted state
      # — verifiable without driving a chat continuation.
      vocation_id = programmer_vocation_id()

      {pid, _agent_id} =
        start_agent(%{
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation_id
        })

      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | next_message_index: 5}}
      end)

      # Three-message compactor output: leading system with
      # the summary, then user, then assistant. After
      # rebuild: fresh_system at 6, summary_user at 7,
      # user at 8, assistant at 9. Post-swap
      # next_message_index = 5 + 4 + 1 = 10.
      compactor_messages = [
        {:system, %System{index: 0, parts: [%Part.Text{text: "[Summary]"}]}},
        {:user, %User{index: 1, parts: [%Part.Text{text: "u"}], api_logs: []}},
        {:assistant,
         %Nest.Messages.Assistant{index: 2, parts: [%Part.Text{text: "a"}], api_logs: []}}
      ]

      send(
        pid,
        {:compaction_done, compactor_messages, {:task_compaction_continuation, self()}}
      )

      assert_receive {:task_compaction_done, _}, 200

      state_after = :sys.get_state(pid)
      # 4 new messages (fresh_system, summary_user, user, assistant)
      assert length(state_after.chat_state.messages) == 4
      assert state_after.chat_state.next_message_index == 10

      Agent.terminate(pid)
    end
  end

  describe "chat:compaction broadcast (regression: optimistic/server race)" do
    @describetag :persistence_enabled

    test "skips the chat:compaction PubSub broadcast when the DB write fails (Bug 3)" do
      # The original `overall-crawdad` crash: the marker
      # INSERT hit a unique-constraint violation (marker
      # tried to take `last_index + 1`, but the fresh system
      # had already been persisted at that index). The DB
      # transaction rolled back, the marker was never
      # written, AND the broadcast was still sent. The
      # AgentChannel crashed with `FunctionClauseError`
      # because there was no handler for the message.
      #
      # Post-fix, the broadcast is gated on the DB write's
      # success. We trigger a real DB failure by pre-inserting
      # a row at the marker_index, so the marker's INSERT hits
      # the `(agent_id, message_index)` unique constraint and
      # the transaction rolls back. The wrapper's
      # `do_archive_and_compact/4` logs the warning, returns
      # `{:error, :rollback}`, and `persist_and_broadcast/5`
      # logs the second warning and skips the broadcast.
      previous = Application.get_env(:nest, :persistence, %{})
      Application.put_env(:nest, :persistence, enabled: true)
      on_exit(fn -> Application.put_env(:nest, :persistence, previous) end)

      vocation_id = programmer_vocation_id()

      # Bypass `start_agent/1` for this test: it calls
      # `Mimic.allow/3` (and we don't need stubs here) and
      # we want fine-grained control over the agent row and
      # pre-inserted collision row.
      agent_name = "test-agent-#{Elixir.System.unique_integer([:positive])}"

      attrs = %{
        name: agent_name,
        model: %{name: "qwen3.5-plus", provider: "model-studio"},
        vocation_id: vocation_id,
        vocation: Init.load_vocation(vocation_id)
      }

      # Insert the agent row BEFORE `start_supervised!` so the
      # Agent's `init/1` -> `persist_initial_system_message/1` ->
      # `append_message` finds the row and succeeds cleanly. The
      # row also needs to exist for the post-compaction marker
      # INSERT (tested below via Bug 3's `archive_and_compact`
      # collision path).
      {:ok, _} =
        Nest.Persistence.insert_agent(%{
          name: agent_name,
          model: %{name: "qwen3.5-plus"},
          vocation_id: vocation_id
        })

      pid = start_supervised!({Agent, attrs})

      # Pre-insert a row at marker_index (= 1) so the marker's
      # INSERT will hit the unique constraint. The
      # `regenerate_for_compaction/2` persists the fresh
      # system at marker_index + 1 (= 2); the marker
      # INSERT at marker_index (= 1) on a different role
      # collides on `(agent_id, message_index)`.
      {:ok, _} =
        Nest.Persistence.insert_message(
          agent_name,
          {:user, %User{index: 1, parts: [%Part.Text{text: "pre-existing"}]}}
        )

      :sys.replace_state(pid, fn state ->
        %{state | chat_state: %{state.chat_state | next_message_index: 1}}
      end)

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_name}")

      log =
        capture_log(fn ->
          send(
            pid,
            {:compaction_done, compactor_output(), {:task_compaction_continuation, self()}}
          )

          assert_receive {:task_compaction_done, _}, 500
        end)

      # The wrapper logged the DB failure.
      assert log =~ "Failed to persist compaction"

      # The new code logged the broadcast skip.
      assert log =~ "Compaction DB write failed"
      assert log =~ "skipping chat:compaction broadcast"

      # No `chat:compaction` broadcast was sent.
      refute_receive {:chat_compaction, _payload}, 100

      Agent.terminate(pid)
    end
  end
end
