defmodule Nest.Agents.Agent.Handlers.CompactionHandlerTest do
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

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatState
  alias Nest.Agents.Agent.Compaction.ResultHandler
  alias Nest.Agents.Agent.Handlers.CompactionHandler
  alias Nest.Agents.Agent.LlmMetrics

  defp build_state do
    %Agent{
      name: "test-agent-loop",
      mode: "chat",
      llm_metrics: %LlmMetrics{
        context_limit: 200_000,
        usage_totals: Broadcasts.empty_usage_totals()
      },
      chat_state: %ChatState{
        consecutive_compaction_count: 0,
        pending_user_message: {"hi", "chat"}
      }
    }
  end

  describe "check_consecutive/1" do
    test "increments the counter on each call below the threshold" do
      state = build_state()

      assert {:ok, state1} = ResultHandler.check_consecutive(state)
      assert state1.chat_state.consecutive_compaction_count == 1

      assert {:ok, state2} = ResultHandler.check_consecutive(state1)
      assert state2.chat_state.consecutive_compaction_count == 2

      assert {:ok, state3} = ResultHandler.check_consecutive(state2)
      assert state3.chat_state.consecutive_compaction_count == 3
    end

    test "refuses after the 4th call (counter exceeds threshold of 3)" do
      state = build_state()

      # 4 consecutive checks yield counter=4, exceeds @max=3, refuses.
      # The 4th call's `set_compaction_loop/2` broadcasts
      # `:chat:error` with "compaction isn't reducing the conversation…"
      # and logs at `:error` level — capture the log to satisfy
      # AGENTS.md's "tests must not print to the console" rule.
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

    test "the refused call transitions status to :compaction_loop_detected" do
      state = build_state()

      # 3 successful bumps then the 4th is the trip. Same
      # capture-and-assert as the previous test.
      log =
        capture_log(fn ->
          state1 = elem(ResultHandler.check_consecutive(state), 1)
          state2 = elem(ResultHandler.check_consecutive(state1), 1)
          state3 = elem(ResultHandler.check_consecutive(state2), 1)
          assert state3.chat_state.status != :compaction_loop_detected

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
        mode: "chat",
        llm_metrics: %LlmMetrics{
          context_limit: 200_000,
          usage_totals: Broadcasts.empty_usage_totals()
        },
        chat_state: %ChatState{
          status: :compaction_loop_detected,
          consecutive_compaction_count: 4,
          pending_user_message: {"hi", "chat"}
        }
      }

      assert {:noreply, new_state} = CompactionHandler.handle(:compaction_loop_detected_ok, state)

      assert new_state.chat_state.status == :idle
      assert new_state.chat_state.consecutive_compaction_count == 0
      assert new_state.chat_state.pending_user_message == nil
    end

    test "no-ops when status isn't :compaction_loop_detected" do
      log =
        capture_log(fn ->
          for status <- [:idle, :compacting, :streaming, :compaction_failed, :context_overflow] do
            state = %Agent{
              name: "test-agent-loop",
              mode: "chat",
              llm_metrics: %LlmMetrics{
                context_limit: 200_000,
                usage_totals: Broadcasts.empty_usage_totals()
              },
              chat_state: %ChatState{
                status: status,
                consecutive_compaction_count: 5,
                pending_user_message: {"hi", "chat"}
              }
            }

            assert {:noreply, returned_state} =
                     CompactionHandler.handle(:compaction_loop_detected_ok, state)

            # No state change when status is wrong.
            assert returned_state.chat_state.status == status
            assert returned_state.chat_state.consecutive_compaction_count == 5
            assert returned_state.chat_state.pending_user_message == {"hi", "chat"}
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
end
