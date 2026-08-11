defmodule Nest.Agents.Agent.Compaction.ResultHandlerTest do
  @moduledoc """
  Tests for the compaction-loop breaker.

  Pinned behavior:

    * `check_consecutive/1` increments the counter on each call
      and refuses after `@max_consecutive_compactions` consecutive
      spawns without progress.
    * `:compaction_loop_detected` status is set on the loop trip.
    * `:compaction_loop_detected_ok/1` returns the agent to
      `:idle`, resets the counter, and clears the pending user
      message.
    * `:compaction_loop_detected_ok/1` is a no-op when status isn't
      `:compaction_loop_detected`.

  Counter resets on `:user` / `:assistant` / `:tool` appends are
  covered in `Nest.Agents.Agent.handle_call({:append_message, _})`
  (test/nest/agents/agent_test.exs).
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatState
  alias Nest.Agents.Agent.ChatState.Live
  alias Nest.Agents.Agent.Compaction.ResultHandler
  alias Nest.Agents.Agent.LlmMetrics

  defp build_state do
    %Agent{
      name: "test-agent-loop",
      llm_metrics: %LlmMetrics{
        context_limit: 200_000,
        usage_totals: Broadcasts.empty_usage_totals()
      },
      chat_state: %ChatState{},
      live: %Live{
        mode: "chat",
        consecutive_compaction_count: 0,
        pending_user_message: {"hi", "chat"}
      }
    }
  end

  describe "check_consecutive/1" do
    test "increments the counter on each call below the threshold" do
      state = build_state()

      assert {:ok, state1} = ResultHandler.check_consecutive(state)
      assert state1.live.consecutive_compaction_count == 1

      assert {:ok, state2} = ResultHandler.check_consecutive(state1)
      assert state2.live.consecutive_compaction_count == 2

      assert {:ok, state3} = ResultHandler.check_consecutive(state2)
      assert state3.live.consecutive_compaction_count == 3
    end

    test "refuses after the 4th call (counter exceeds threshold of 3)" do
      state = build_state()

      # 4 consecutive checks yield counter=4, exceeds @max=3, refuses.
      # The 4th call's `set_compaction_loop/3` broadcasts
      # `chat:compaction-loop` with "compaction isn't reducing the
      # conversation…" and logs at `:error` level — capture the log
      # to satisfy AGENTS.md's "tests must not print to the console"
      # rule.
      log =
        capture_log(fn ->
          final =
            Enum.reduce(1..4, state, fn _, acc ->
              case ResultHandler.check_consecutive(acc) do
                {:ok, next} -> next
                :refuse -> :refused
              end
            end)

          assert final == :refused
        end)

      assert log =~ "compaction isn't reducing the conversation"
    end

    test "the loop trip broadcasts attempt_count and max_attempts in the payload" do
      # Start the counter at the limit (3); the next check makes the
      # would-be 4th compaction exceed it, tripping the loop.
      state = %{build_state() | space_id: 12_345}
      state = %{state | live: %{state.live | consecutive_compaction_count: 3}}

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:12345:test-agent-loop")

      capture_log(fn ->
        :refuse = ResultHandler.check_consecutive(state)
      end)

      # attempt_count = the consecutive compactions that already
      # happened (3); max_attempts = the configured limit (3).
      assert_receive {:chat_compaction_loop, %{content: _, attempt_count: 3, max_attempts: 3}}
    end

    test "the refused call transitions status to :compaction_loop_detected" do
      state = build_state()

      # 3 successful bumps then the 4th is the trip. Same
      # capture-and-assert as the previous test.
      log =
        capture_log(fn ->
          state1 = elem(ResultHandler.check_consecutive(state), 1)
          state2 = elem(ResultHandler.check_consecutive(state1), 1)
          state3 = elem(ResultHandler.check_consecutive(state2), 1)
          assert state3.live.status != :compaction_loop_detected

          # 4th bumps to 4, exceeds threshold, refuses.
          :refuse = ResultHandler.check_consecutive(state3)
        end)

      assert log =~ "compaction isn't reducing the conversation"
    end
  end

  describe "compaction_loop_detected_ok/1" do
    test "transitions :compaction_loop_detected → :idle, resets counter, clears pending user message" do
      state = %Agent{
        name: "test-agent-loop",
        llm_metrics: %LlmMetrics{
          context_limit: 200_000,
          usage_totals: Broadcasts.empty_usage_totals()
        },
        chat_state: %ChatState{},
        live: %Live{
          mode: "chat",
          status: :compaction_loop_detected,
          consecutive_compaction_count: 4,
          pending_user_message: {"hi", "chat"}
        }
      }

      assert {:noreply, new_state} = ResultHandler.handle(:compaction_loop_detected_ok, state)

      assert new_state.live.status == :idle
      assert new_state.live.consecutive_compaction_count == 0
      assert new_state.live.pending_user_message == nil
    end

    test "no-ops when status isn't :compaction_loop_detected" do
      log =
        capture_log(fn ->
          for status <- [:idle, :compacting, :streaming, :compaction_failed, :context_overflow] do
            state = %Agent{
              name: "test-agent-loop",
              llm_metrics: %LlmMetrics{
                context_limit: 200_000,
                usage_totals: Broadcasts.empty_usage_totals()
              },
              chat_state: %ChatState{},
              live: %Live{
                mode: "chat",
                status: status,
                consecutive_compaction_count: 5,
                pending_user_message: {"hi", "chat"}
              }
            }

            assert {:noreply, returned_state} =
                     ResultHandler.handle(:compaction_loop_detected_ok, state)

            # No state change when status is wrong.
            assert returned_state.live.status == status
            assert returned_state.live.consecutive_compaction_count == 5
            assert returned_state.live.pending_user_message == {"hi", "chat"}
          end
        end)

      # The loop exercises 5 wrong-status values; each one fires
      # `Logger.warning("compaction_loop_detected_ok ignored: ...")`
      # from `compaction_handler.ex`. AGENTS.md forbids noisy
      # test output. Capture-and-assert: the warning string is
      # present in the captured log.
      for status <- [:idle, :compacting, :streaming, :compaction_failed, :context_overflow] do
        assert log =~ "status=#{inspect(status)}"
      end
    end
  end

  describe "retry_compaction/1" do
    # `retry_compaction/1` has two branches: when `mid_turn_entry`
    # is set, it dispatches to `needs_entry/2` (carries the
    # mid-turn entry forward); when nil, it dispatches to
    # `Trigger.post_turn/1` (resumes from a held user message).
    # Both branches run through `Trigger.start/2` and would spawn
    # a ChatTurn — the unit test sets `vocation: nil` and
    # `messages: []` so `render_system_prompt/2` returns nil and
    # `start/2` short-circuits to `broadcast_reserve_exhausted/2`
    # (no spawn). The catch is the `Logger.error/2` that the
    # reserve-exhausted broadcast path fires, which `capture_log`
    # swallows.
    #
    # The branch observable is the post-state `mid_turn_entry`
    # field:
    #   * `needs_entry` clears it then re-sets it to
    #     `%{entry: carried_entry}` so the next ChatTurn sees
    #     the carried tool_call continuation.
    #   * `Trigger.post_turn` does not touch it.
    # Both branches broadcast `{:chat_status, %{status: "compacting"}}`
    # at the same point, so the broadcast alone is not
    # branch-distinguishing.

    test "needs_entry path: mid_turn_entry is re-set after clear_mid_turn_entry" do
      state = build_state()

      state = %{
        state
        | live: %{
            state.live
            | status: :compaction_failed,
              mid_turn_entry: %{entry: :synthetic_carried_entry}
          }
      }

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      _ =
        capture_log(fn ->
          result = ResultHandler.retry_compaction(state)

          # Branch assertion: `needs_entry/2` re-set `mid_turn_entry`
          # (after `clear_mid_turn_entry/1` briefly cleared it).
          # `Trigger.post_turn/1` would have left it nil.
          assert result.live.status == :compacting
          assert result.live.mid_turn_entry == %{entry: :synthetic_carried_entry}

          # External observable: the `:compacting` broadcast fired.
          assert_receive {:chat_status, %{status: "compacting"}}
        end)
    end

    test "Trigger.post_turn path: mid_turn_entry stays nil when not set" do
      state = build_state()

      state = %{
        state
        | live: %{state.live | status: :compaction_failed, mid_turn_entry: nil}
      }

      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.space_id}:#{state.name}")

      _ =
        capture_log(fn ->
          result = ResultHandler.retry_compaction(state)

          # Branch assertion: `Trigger.post_turn/1` does not touch
          # `mid_turn_entry`. If `needs_entry/2` had been called,
          # `mid_turn_entry` would have been re-set to
          # `%{entry: carried_entry}`.
          assert result.live.status == :compacting
          assert result.live.mid_turn_entry == nil

          # External observable: the `:compacting` broadcast fired.
          assert_receive {:chat_status, %{status: "compacting"}}
        end)
    end
  end
end
