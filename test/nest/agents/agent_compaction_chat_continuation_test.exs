defmodule Nest.Agents.AgentCompactionChatContinuationTest do
  @moduledoc """
  Regression tests for the post-compaction message-append
  contract. These tests pin three invariants the compaction
  refactor changed:

    * The carried user message (`{:user_message, User.t()}`)
      lands at `state.chat_state.next_message_index` (the
      post-swap bump), not the pre-swap value.
    * The compaction marker is stored at the pre-swap
      `next_message_index` (= `marker_index`), not at
      `marker_index + 1`. A unique-constraint collision with
      the regenerated system message at `marker_index + 1`
      was the original `overall-crawdad` crash.
    * `Compaction.Lifecycle.swap_messages/3` bumps
      `state.chat_state.next_message_index` past the new
      compacted state so the resumed user message doesn't
      stamp below it.

  ## Continuation shapes (post-refactor)

  The continuations carried in `{:compaction_done, _, c}` /
  `{:compaction_failed, _, c}` are the unified
  `Nest.Agents.Agent.ChatTurn.State.continuation/0` shapes:

    * `{:user_message, %User{index: nil, ...}}` — Trigger 1.
      Bare user struct; `append_continuation_tail/2` wraps
      it in `{:user, _}` when appending to
      `state.chat_state.messages`.
    * `{:tool_call, {%assistant, %Assistant{...}}, n, m}` —
      Trigger 2. (Not exercised here.)
    * `{:compact_tool, [{:assistant, _}, {:tool, _}], n, m}` —
      Trigger 3. The carried pair is appended together.

  Legacy tuples (`{:chat_continuation, _}`,
  `{:task_compaction_continuation, _}`,
  `{:mid_turn_continuation, n, m}`) are translated upstream
  by `CompactionHandler.normalize_continuation/2`. These
  tests use the new shapes directly.

  `async: false` for the same reason as the other compaction
  tests (sandbox connection walks `$callers` at the agent
  boundary, async tests lose ownership).
  """
  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  import Nest.Agents.AgentTestHelpers, only: [start_agent: 1]

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Config, as: AgentConfig
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Vocations

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    # Compaction writes flow through AgentPersistence
    # (gated on `persistence_enabled?`). Enable the flag for
    # the duration of the suite so the marker INSERT and the
    # `last_compaction_index` column bump actually hit the DB.
    previous = Application.get_env(:nest, :persistence, %{})
    Application.put_env(:nest, :persistence, enabled: true)

    on_exit(fn ->
      Application.put_env(:nest, :persistence, previous)
      Process.delete(:nest_test_agent_pid)
    end)

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

  # The shared dance for every regression test in this file:
  #
  # 1. Disable persistence so the Agent's init-time
  #    `persist_initial_system_message/1` (which would log
  #    `Failed to persist message…` for `:agent_not_found`) is
  #    a silent no-op.
  # 2. Start the agent via `start_agent/1` (MockClient-wired).
  # 3. Re-enable persistence AND insert the agents row so the
  #    post-compaction marker INSERT and the regenerator's
  #    per-message INSERTs find a target.
  # 4. Pin `next_message_index` so `marker_index` is
  #    well-defined (= the given value).
  #
  # AGENTS.md forbids noisy test output; this dance keeps
  # the suite silent.
  defp start_agent_with_row(next_message_index) do
    vocation_id = programmer_vocation_id()

    Application.put_env(:nest, :persistence, enabled: false)

    {pid, agent_id} =
      start_agent(%{
        model: %{name: "qwen3.5-plus"},
        vocation_id: vocation_id
      })

    Application.put_env(:nest, :persistence, enabled: true)

    Nest.Persistence.insert_agent(%{
      name: agent_id,
      model: %{name: "qwen3.5-plus"},
      vocation_id: vocation_id
    })

    :sys.replace_state(pid, fn state ->
      %{state | chat_state: %{state.chat_state | next_message_index: next_message_index}}
    end)

    {pid, agent_id}
  end

  # Two compactor messages: leading system with the encoded
  # summary, then a user message. The handler extracts the
  # summary from the leading system, re-renders it as a
  # user message at position 1, and re-numbers the rest from
  # position 3.
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

  # The carried pair for a `:compact_tool` continuation:
  # `[{:assistant, +ToolUse}, {:tool, +ToolResult}]`.
  #
  # `iter` defaults to 0 to match the pre-refactor
  # `normalize_continuation/2` literal; `max` defaults to the
  # configured tool-iteration cap. The handler doesn't inspect
  # `state.chat_state.messages` for the trailing tool call —
  # the pair is carried in the continuation itself.
  defp compact_tool_continuation(iter \\ 0, max \\ AgentConfig.configured_max_tool_iterations()) do
    tool_call_id = "compact_call_#{Elixir.System.unique_integer([:positive])}"
    arguments = %{"action" => "compact"}

    tool_call_msg =
      {:assistant,
       %Assistant{
         index: nil,
         parts: [%Part.ToolUse{id: tool_call_id, name: "context", arguments: arguments}],
         api_logs: []
       }}

    tool_result_msg =
      {:tool,
       %Tool{
         index: nil,
         timestamp: DateTime.utc_now(),
         parts: [
           %Part.ToolResult{
             tool_call_id: tool_call_id,
             name: "context",
             arguments: arguments,
             content: "Compacted from N token previous context.",
             is_error: false
           }
         ],
         api_logs: []
       }}

    {:compact_tool, [tool_call_msg, tool_result_msg], iter, max}
  end

  describe "compaction_done: append_continuation_tail stamps at the post-swap next_message_index" do
    test "stamps the carried user message at next_message_index (Bug 1 + Bug 4)" do
      # Pre-fix, `build_user_message/3` returned a 2-tuple, and
      # `next_message_index` was the pre-swap value. Both crashed
      # here. Post-fix, the carried user message lands at the
      # post-swap `next_message_index` (= 5 in this setup:
      # marker_index=1, fresh_system=2, summary_user=3,
      # compactor_user=4, carried_user=5).
      #
      # The pre-refactor test pre-seeded
      # `state.chat_state.pending_user_message` and used the
      # legacy `{:chat_continuation, :pending}` continuation.
      # The post-refactor design carries the user struct in
      # the `{:user_message, User.t()}` continuation directly —
      # no transient field. `append_continuation_tail/2` wraps
      # the bare struct in `{:user, _}` and `compaction_completed`
      # stamps it via the post-swap `next_message_index`.
      {pid, _agent_id} = start_agent_with_row(1)

      # `index: nil` — the handler stamps it during
      # `compaction_completed`. The `[mode: build]\n` prefix
      # mirrors what `ChatPipeline.build_user_message/3` would
      # have emitted so the LLM sees the same on-the-wire format.
      user_msg = %User{
        index: nil,
        parts: [%Part.Text{text: "[mode: build]\nWhat was the last question?"}],
        metadata: %{"mode" => "build"},
        api_logs: []
      }

      send(pid, {:compaction_done, compactor_output(), {:user_message, user_msg}})

      # The handler runs `regenerate_for_compaction/2`,
      # `append_continuation_tail/2`, then
      # `compaction_completed/2`. The pre-fix
      # `put_message_index/2` FunctionClauseError would crash
      # the GenServer here; the test would observe a DOWN rather
      # than a state update. `:sys.get_state/1` queues behind
      # `:compaction_done` and returns only after the
      # same-callback work is done.
      state_after = :sys.get_state(pid, 500)

      # `append_continuation_tail/2` wraps the bare struct in
      # `{:user, _}` so the post-swap `match?` finds it.
      last_user =
        state_after.chat_state.messages
        |> Enum.reverse()
        |> Enum.find(&match?({:user, _}, &1))

      assert last_user != nil, "expected a user message in state.chat_state.messages"

      {_, %User{index: user_index}} = last_user

      # compactor has 2 messages → `regenerate_for_compaction/2`
      # produces 3 (fresh_system@2, summary_user@3,
      # compactor_user@4). Plus the carried user message at @5.
      # Post-swap `next_message_index = marker_index + length +
      # 1 = 1 + 4 + 1 = 6`. The carried user message lands at
      # index 5 (Bug 4 — without the bump the carried user
      # message would stamp at 1, colliding with / sat below
      # the fresh system at 2).
      assert user_index == 5,
             "expected user message at index 5, got #{user_index}"

      assert state_after.chat_state.next_message_index == 6

      Agent.terminate(pid)
    end
  end

  describe "compaction_done: marker and compaction_completed invariants" do
    test "compaction marker is at marker_index, not marker_index + 1 (Bug 2)" do
      # Regression for the marker-index off-by-one: the
      # agent's `chat_state.history` ends with a
      # `{:compaction, _}` marker whose `.index` field is the
      # pre-swap `next_message_index` (= 1 in this setup).
      # Pre-fix the DB-side `record_compaction/3` tried to
      # insert the marker at `last_index + 1 = 2` and
      # collided with the fresh system message that
      # `regenerate_for_compaction/2` had already persisted
      # at index 2.
      #
      # Under the new `:compact_tool` continuation the
      # carried pair [tool_call, tool_result] is appended via
      # `append_continuation_tail/2` — the handler no longer
      # peeks at `state.chat_state.messages` for the trailing
      # tool call.
      {pid, _agent_id} = start_agent_with_row(1)

      send(pid, {:compaction_done, compactor_output(), compact_tool_continuation()})

      # `:task_compaction_done` is gone in the new design —
      # the handler synchronously appends the carried pair
      # via `append_continuation_tail/2` and spawns a fresh
      # ChatTurn via `ChatTurnSpawner.spawn/4`. We don't
      # care about the spawned ChatTurn's downstream work
      # for this test — just that the marker index and the
      # first new message are correct.
      _ = :sys.get_state(pid, 500)

      state_after = :sys.get_state(pid)

      [{:compaction, marker} | _] = Enum.reverse(state_after.chat_state.history)

      assert marker.index == 1,
             "expected marker index == 1, got #{marker.index}"

      # The new compacted state's first row is the fresh
      # system at marker_index + 1.
      [first | _] = state_after.chat_state.messages
      assert {_, %{index: 2}} = first

      Agent.terminate(pid)
    end

    test "swap_messages bumps next_message_index past the new compacted state (Bug 4)" do
      # Without the bump, the resumed user message in the
      # first test would be stamped at the pre-swap value
      # (1), below the fresh system (2). With the bump, the
      # post-swap `next_message_index` is one past the new
      # compacted state — verifiable without driving a chat
      # continuation.
      #
      # Under the new `:compact_tool` continuation, the
      # carried [tool_call, tool_result] pair adds 2 more
      # rows to the post-swap messages list than the legacy
      # `{:task_compaction_continuation, _}` path did. The
      # bump test still verifies that `next_message_index`
      # is one past the LAST row, not stuck at the legacy
      # 4-row boundary.
      {pid, _agent_id} = start_agent_with_row(5)

      # Three-message compactor output: leading system with
      # the summary, then user, then assistant. After
      # rebuild: fresh_system at 6, summary_user at 7,
      # user at 8, assistant at 9. Plus the `:compact_tool`
      # carried pair (tool_call, tool_result) appended via
      # `append_continuation_tail/2`, stamped at 10 and 11.
      # Post-swap next_message_index = 5 + 6 + 1 = 12.
      compactor_messages = [
        {:system, %System{index: 0, parts: [%Part.Text{text: "[Summary]"}]}},
        {:user, %User{index: 1, parts: [%Part.Text{text: "u"}], api_logs: []}},
        {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "a"}], api_logs: []}}
      ]

      send(
        pid,
        {:compaction_done, compactor_messages, compact_tool_continuation()}
      )

      _ = :sys.get_state(pid, 500)

      state_after = :sys.get_state(pid)

      # 6 messages: fresh_system, summary_user, user,
      # assistant, tool_call, tool_result. The bump from 4
      # to 6 reflects the carried pair appended by
      # `append_continuation_tail/2`.
      assert length(state_after.chat_state.messages) == 6,
             "expected 6 messages, got #{length(state_after.chat_state.messages)}"

      assert state_after.chat_state.next_message_index == 12,
             "expected next_message_index == 12, got #{state_after.chat_state.next_message_index}"

      Agent.terminate(pid)
    end
  end

  describe "chat:compaction broadcast (regression: optimistic/server race)" do
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
      # success. We trigger a real DB failure by
      # pre-inserting a row at the marker_index, so the
      # marker's INSERT hits the `(agent_id, message_index)`
      # unique constraint and the transaction rolls back.
      # The wrapper's `do_record_compaction/3` logs the
      # warning, returns `{:error, reason}`, and
      # `persist_and_broadcast/5` logs the second warning
      # and skips the broadcast.
      #
      # Migration note: the `:compact_tool` continuation
      # carries the tool_call/tool_result pair directly, so
      # the chat task no longer needs to receive the
      # `{:task_compaction_done, _}` reply to unblock its
      # receive — the handler appends the pair inline. We
      # wait for the handler via `_ = :sys.get_state/2`
      # rather than an `assert_receive` on the reply.
      #
      # `start_agent/1` (rather than a raw
      # `start_supervised!({Agent, _})`) so MockClient is
      # wired up — the new path spawns a fresh ChatTurn at
      # the end of `compaction_done`, and the spawned turn
      # would otherwise try to make a real HTTP call (via
      # OpenAIClient → ReqNullAdapter → raises) for the
      # post-swap resumption. The MockClient queue is empty
      # so the turn returns a random text response and
      # finalizes; the test asserts on log + broadcast, not
      # on the turn's output.
      {pid, agent_name} = start_agent_with_row(1)

      # `start_agent/1` doesn't insert the agents row — we
      # do so explicitly via `start_agent_with_row/1`. Now
      # pre-insert a row at marker_index (= 1) so the
      # marker's INSERT will hit the unique constraint.
      # The `regenerate_for_compaction/2` persists the
      # fresh system at marker_index + 1 (= 2); the marker
      # INSERT at marker_index (= 1) on a different role
      # collides on `(agent_id, message_index)`.
      {:ok, _} =
        Nest.Persistence.insert_message(
          agent_name,
          {:user, %User{index: 1, parts: [%Part.Text{text: "pre-existing"}]}}
        )

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_name}")

      log =
        capture_log(fn ->
          send(pid, {:compaction_done, compactor_output(), compact_tool_continuation()})

          # `:task_compaction_done` is gone in the new
          # design. `:sys.get_state/2` queues behind the
          # compaction handler and returns only after the
          # marker INSERT (which fails), the DB rollback,
          # and the broadcast-skip log line have all run.
          _ = :sys.get_state(pid, 500)
        end)

      assert log =~ "Failed to persist compaction"
      assert log =~ "Compaction DB write failed"
      assert log =~ "skipping chat:compaction broadcast"

      refute_receive {:chat_compaction, _payload}, 100

      Agent.terminate(pid)
    end
  end
end
