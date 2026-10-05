defmodule Nest.Agents.AgentTurnIterationTest do
  @moduledoc """
  Tests for the mid-turn compaction flow.

  The flow:

    * `ChatTurn.handle_response/2` runs `BatchSizer.preflight/2`
      on the projected tool results. If the projected total
      would push the conversation past
      `(context_limit - reserve)`, the ChatTurn exits cleanly
      with `{:needs_compaction, self(), continuation}` where
      `continuation` carries the carried tool_call message +
      iteration count.
    * The Agent receives `:needs_compaction`, sets
      `:compacting` status, and spawns the compactor with
      the `{:tool_call, <msg>, iter, max}` continuation
      (the unified `ChatTurn.State.continuation/0` shape).
    * On compaction success, the Agent spawns a fresh
      ChatTurn with the same continuation. The new ChatTurn
      sees the compacted messages and the carried
      assistant+ToolUse at the tail, and executes the LLM's
      already-emitted tool calls rather than calling the LLM
      again.
    * Iteration count is preserved across the compaction
      boundary so the tool-call iteration limit is enforced
      continuously.

  These tests exercise the wiring directly via
  `:sys.replace_state` and message sends, rather than
  driving the full streaming chat turn (which would require
  mocking the LLM stream and tool execution pipeline).
  """

  use Nest.DataCase, async: true
  alias Nest.Agents.Agent.Machine

  import Eventually
  import ExUnit.CaptureLog
  import Mimic

  import Nest.Agents.AgentTestHelpers

  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.User

  setup :verify_on_exit!

  setup do
    Process.put(:nest_test_agent_pid, self())
    MockClient.start_link()
    MockClient.clear()

    on_exit(fn -> Process.delete(:nest_test_agent_pid) end)

    :ok
  end

  defp start_test_agent do
    # The standard helper handles row insertion (via
    # `Agent.pre_spawn/1`), supervisor spawn, sandbox allow
    # (so spawned ChatTurn pids can do DB writes), and
    # MockClient swap. The synthetic tool calls in this
    # file use `name: "context-compact"`, which the helper's
    # default "Test Default" vocation includes in its
    # `tools: ["context-check", "context-compact"]`. The "build" mode and extra
    # tools from the previous bespoke `programmer_vocation_id`
    # were never read by any handler exercised here.
    start_agent()
  end

  # Synthetic assistant+ToolUse used as the carried tool_call
  # message in the `{:tool_call, msg, iter, max}` continuation.
  # The shape and ids don't matter for the wiring tests — only
  # that the carried message is a `{:assistant, %Assistant{}}`
  # tuple whose parts include at least one `%Part.ToolUse{}`
  # so the resumed ChatTurn's `pending_tool_calls?/1` check
  # finds a real outstanding tool call at the messages tail.
  defp synthetic_tool_call_msg do
    {:assistant,
     %Assistant{
       index: 0,
       parts: [
         %Part.ToolUse{
           id: "call_1",
           name: "context-compact",
           arguments: %{}
         }
       ],
       api_logs: []
     }}
  end

  describe ":needs_compaction handler (mid-turn trigger)" do
    test "Agent transitions to :compacting when :needs_compaction arrives" do
      {pid, _name} = start_test_agent()

      capture_log(fn ->
        # `:needs_compaction` now carries the full
        # `ChatTurn.State.continuation/0` payload — the
        # outstanding assistant+ToolUse + iteration count.
        send(pid, {:needs_compaction, self(), {:tool_call, synthetic_tool_call_msg(), 5, 30}})

        # The handler sets status to :compacting and spawns
        # the compactor. The status broadcast is the
        # observable signal.
        assert_receive {:chat_status, %{status: "compacting"}}, 500

        # With no pre-seeded conversation beyond the init
        # system message, the compactor's `:too_short` branch
        # fires (`{:compaction_done, :passthrough, _}`). The
        # handler must return the agent to `:idle` cleanly
        # (no GenServer crash, no orphan continuation) — this
        # pins the `handle_passthrough/2` wrap that prevents
        # the "bad return value" crash.
        assert_receive {:chat_status, %{status: "idle"}}, 1_000

        # No `chat:error` broadcast — the skip is a clean
        # recovery, not a failure.
        refute_receive {:chat_error, _}, 200
      end)
    end

    test "Agent passes iteration and max_iterations through to the compactor" do
      {pid, _name} = start_test_agent()

      capture_log(fn ->
        :sys.replace_state(pid, fn state ->
          messages = [
            {:system,
             %Nest.Messages.System{
               index: 0,
               parts: [%Part.Text{text: "System"}],
               api_logs: []
             }},
            {:user, %User{index: 1, parts: [%Part.Text{text: "Hello"}], api_logs: []}}
          ]

          %{state | chat_state: %{state.chat_state | messages: messages}}
        end)

        # The final text response for the resumed turn's second LLM
        # iteration (after the carried tool call executes).
        MockClient.set_response("done")

        # Send compaction_done with the unified
        # `{:tool_call, msg, iter, max}` continuation. The
        # carried `msg` is synthetic — what matters for this
        # test is that the new ChatTurn spawns and runs,
        # producing a chat:status broadcast the test can
        # observe.
        send_compaction_done(pid, "Summary", {:tool_call, synthetic_tool_call_msg(), 25, 30})

        # The new ChatTurn spawns and runs. With the carried
        # assistant+ToolUse at the tail, the ChatTurn's
        # `pending_tool_calls?/1` returns true and it
        # executes the carried tool call (context-compact,
        # which BatchSizer strips → empty result); then the
        # next iteration falls through to the LLM and the
        # chat turn finalizes with a chat:status broadcast.
        #
        # The first status after the swap is the resumed
        # `:executing_tools` (a `{:tool_call, ...}` continuation
        # executes the carried tool calls first). Broadcasting it
        # is what pulls the UI out of the stale `:compacting`.
        assert_receive {:chat_status, %{status: "executing_tools"}}, 500
        # Finish the resumed turn so the agent is idle when the
        # test ends (the teardown asserts zero in-flight agents).
        # Poll the agent's status instead of waiting on the idle
        # broadcast in a fixed window: the resumed LLM iteration
        # can land after 100ms under coverage/load.
        assert eventually(
                 fn ->
                   Machine.status_for(:sys.get_state(pid).live.machine) == :idle
                 end,
                 timeout: 1_000
               )
      end)
    end
  end

  describe "mid_turn_entry field lifecycle" do
    test "mid_turn_entry is cleared on successful compaction_done" do
      {pid, _name} = start_test_agent()

      # Pre-seed mid_turn_entry as if a mid-turn
      # compaction is in progress. The new field shape
      # carries the full continuation payload (not just
      # the iteration counters) so a future retry can
      # resume with the same carry-forward semantics.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | live: %{
              state.live
              | mid_turn_entry: %{
                  entry: {:tool_call, synthetic_tool_call_msg(), 7, 30}
                }
            }
        }
      end)

      capture_log(fn ->
        # The final text response for the resumed turn's second LLM
        # iteration (after the carried tool call executes).
        MockClient.set_response("done")

        send_compaction_done(pid, "Summary", {:tool_call, synthetic_tool_call_msg(), 7, 30})

        # Wait for the compactor to finish and the new
        # ChatTurn to spawn. The new ChatTurn iterates
        # (the carried tool_call triggers
        # `execute_pending_tool_calls`, which yields an
        # empty BatchSizer run after the context-compact
        # strip), then falls through to the LLM and
        # finalizes — broadcasting chat:status along the
        # way. The first is the resumed `:executing_tools`.
        assert_receive {:chat_status, %{status: "executing_tools"}}, 500
        # Finish the resumed turn so the agent is idle when the
        # test ends (the teardown asserts zero in-flight agents).
        # Poll the agent's status instead of waiting on the idle
        # broadcast in a fixed window: the resumed LLM iteration
        # can land after 100ms under coverage/load.
        assert eventually(
                 fn ->
                   Machine.status_for(:sys.get_state(pid).live.machine) == :idle
                 end,
                 timeout: 1_000
               )
      end)

      state_after = :sys.get_state(pid)
      assert state_after.live.mid_turn_entry == nil
    end
  end

  describe "mid_turn_entry carries the trailing assistant+ToolUse forward" do
    # Regression for the field bug: when mid-turn compaction fires, the
    # LLM's emitted tool calls used to be archived into history along
    # with the rest of the pre-compaction messages, leaving the new
    # ChatTurn with no assistant+ToolUse at the tail. The resumed
    # ChatTurn would then trip its iteration dispatch with no
    # outstanding tool call to execute, and the chat turn would fall
    # straight through to the LLM — losing the LLM's already-emitted
    # tool calls.
    test "post-compaction messages end [system, summary_user, assistant+ToolUse]" do
      {pid, _name} = start_test_agent()

      # Pre-seed: messages list contains a trailing assistant message
      # with a ToolUse part. This is what the chat task appends when
      # the LLM emits tool calls; the carried message is what the
      # `{:tool_call, msg, iter, max}` continuation preserves through
      # the compactor's swap.
      assistant_with_tool_use =
        {:assistant,
         %Assistant{
           index: 2,
           parts: [
             %Part.Text{text: "I'll check context."},
             %Part.ToolUse{
               id: "call_1",
               name: "context-check",
               arguments: %{}
             }
           ],
           api_logs: []
         }}

      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | messages: [
                  {:system,
                   %Nest.Messages.System{
                     index: 0,
                     parts: [%Part.Text{text: "Base."}],
                     api_logs: []
                   }},
                  {:user,
                   %User{
                     index: 1,
                     parts: [%Part.Text{text: "Read /tmp/example.txt"}],
                     api_logs: []
                   }},
                  assistant_with_tool_use
                ]
            }
        }
      end)

      summary_text = "Head summary from the LLM."

      log =
        capture_log(fn ->
          # Pass the carried tool_call_msg directly via the
          # `{:tool_call, msg, iter, max}` entry shape.
          send_compaction_done(
            pid,
            summary_text,
            {:tool_call, assistant_with_tool_use, 3, 30}
          )

          # Drain the agent's mailbox before inspecting state. The
          # compaction handler does the swap, persists/broadcasts,
          # then starts the new in-process turn synchronously inside
          # the same `{:noreply, state}` return.
          _ = :sys.get_state(pid)

          # Capture the in-process turn while it is still live — it
          # iterates and finalizes promptly once MockClient returns,
          # after which `live.turn` is reset. The turn state below is
          # read here so the carry-forward assertions can run before
          # that happens.
          turn = :sys.get_state(pid).live.turn
          send(self(), {:turn_captured, turn})
        end)

      assert_receive {:turn_captured, turn}, 1_000
      assert turn.entry == {:tool_call, assistant_with_tool_use, 3, 30}

      # Post-compaction, the agent's chat_state.messages is the
      # canonical shape:
      #   [system_fresh, summary_user, carried_assistant+ToolUse]
      #
      # - `system_fresh` is re-rendered from the latest DB vocation
      #   and on-disk AGENTS.md via
      #   `SystemPrompt.compose_vocation_config/4` and is at index
      #   `marker_index + 1`. AGENTS.md allows the system message
      #   to change at compaction because the prefix cache is
      #   invalidated.
      # - `summary_user` is the compactor's "Summary of earlier
      #   conversation:\n\n<text>" message at `marker_index + 2`.
      # - The carried assistant+ToolUse is appended via the
      #   canonical message path at `marker_index + 3` (its
      #   pre-seeded `index: 2` is overwritten by `append_one/2`'s
      #   `put_message_index/2`).
      final_messages = :sys.get_state(pid).chat_state.messages

      # The resumed turn immediately executes the carried
      # `context-check` tool call, which appends a `tool` result (and
      # then the final text response) to the agent's messages. So
      # `final_messages` may have grown past 3 by the time we read it —
      # the exact count races the turn's async tool execution. The
      # post-compaction canonical shape is always the FIRST three entries
      # (system, summary_user, carried assistant+ToolUse); assert on
      # those deterministically rather than racing the turn.
      canonical = Enum.take(final_messages, 3)

      assert length(canonical) == 3,
             "expected [system, summary_user, assistant+ToolUse]; " <>
               "got #{inspect(final_messages)}"

      assert match?({:system, _}, Enum.at(canonical, 0))
      assert match?({:user, _}, Enum.at(canonical, 1))

      # The carried-forward trailing assistant message must carry the
      # original ToolUse parts (the renumbering pass in
      # `Compaction.Lifecycle.swap_messages/3` assigns fresh indices
      # to the whole `new_messages` list, so we compare on shape
      # rather than full struct equality).
      {tail_role, tail_struct} = List.last(canonical)
      assert tail_role == :assistant

      assert Enum.any?(
               tail_struct.parts,
               &match?(%Part.ToolUse{id: "call_1", name: "context-check"}, &1)
             )

      # The turn's `entry` is the carried entry itself — the
      # `{:tool_call, msg, iter, max}` shape — and its request context
      # still carries the trailing assistant+ToolUse.
      {ctx_tail_role, ctx_tail_struct} = List.last(turn.ctx.messages)
      assert ctx_tail_role == :assistant
      assert Enum.any?(ctx_tail_struct.parts, &match?(%Part.ToolUse{id: "call_1"}, &1))

      # Wait for the resumed turn to fully complete before the test
      # returns. The carried `context-check` result is appended via
      # `{:tool_results_received, _}` asynchronously; the idle broadcast
      # (from `TurnHandler.chat_idle_state/1`) fires only once that append
      # and the final LLM response are done. Without this barrier the
      # agent's in-flight DB write races the test's sandbox-owner exit,
      # producing the intermittent "owner exited" Postgrex disconnect.
      assert_receive {:chat_status, %{status: "idle"}}, 500

      # Silence the unused-variable warning on `log` — captured so
      # debugging output (if any) lands in the test report.
      _ = log
    end
  end

  describe "mid-turn re-compaction of a still-refused tool batch" do
    # Regression: the resumed ChatTurn used to emit a stale 4-tuple
    # `{:needs_compaction, pid, iteration, max_iterations}` that no
    # handler matched, so a compactor that still couldn't make room
    # stalled the turn silently. It must emit the unified 3-tuple
    # continuation (like every other emitter) so the Agent re-enters
    # `:compacting`.
    test "a still-refused batch asks the Agent to compact again" do
      {pid, _name} = start_test_agent()

      # A tool-result projection big enough to refuse the batch on its
      # own: the `file-read` projection stats the file (~1 MiB), which
      # estimates to well over the 128k context limit. The file is only
      # stat'ed, never tokenized, so its contents are irrelevant.
      big =
        Path.join(
          System.tmp_dir!(),
          "nest_iter_big_#{System.unique_integer([:positive])}.bin"
        )

      File.write!(big, :binary.copy(<<0>>, 1_048_576))
      on_exit(fn -> File.rm(big) end)

      carried =
        {:assistant,
         %Assistant{
           index: 0,
           parts: [
             %Part.ToolUse{
               id: "call_big",
               name: "file-read",
               arguments: %{"path" => big}
             }
           ],
           api_logs: []
         }}

      :sys.replace_state(pid, fn state ->
        messages = [
          {:system,
           %Nest.Messages.System{
             index: 0,
             parts: [%Part.Text{text: "System"}],
             api_logs: []
           }},
          {:user, %User{index: 1, parts: [%Part.Text{text: "Do the thing"}], api_logs: []}},
          carried
        ]

        # Pin the context limit so the 1 MiB `file-read` projection
        # (~314k tokens) overflows it and the batch is refused. The loop
        # breaker is already at its limit, so the re-compaction request
        # surfaces as an observable status transition instead of spawning
        # another compactor.
        %{
          state
          | chat_state: %{state.chat_state | messages: messages},
            live: %{state.live | consecutive_compaction_count: 3},
            llm_metrics: %{state.llm_metrics | context_limit: 128_000}
        }
      end)

      capture_log(fn ->
        send_compaction_done(pid, "Summary", {:tool_call, carried, 5, 30})

        # The resumed turn re-preflights, refuses, and emits the 3-tuple
        # `:needs_compaction`, which routes to `ResultHandler.needs_entry/2`
        # → `:compacting`. Without the unified continuation the request is
        # unroutable, so no `:compacting` ever arrives.
        assert_receive {:chat_status, %{status: "compacting"}}, 500

        # End deterministically: stop the in-flight compactor so the agent
        # is idle at teardown. (Loop-breaker coverage lives in
        # `Nest.Agents.Agent.Compaction.ResultHandlerTest`.)
        assert :ok = Nest.Agents.Agent.stop_chat(pid, self())
        assert_receive {:chat_status, %{status: "idle"}}, 1_000
      end)
    end
  end

  # Regression coverage for the "25% context warning fires on every
  # user message past 25%" bug lives in
  # `Nest.Agents.AgentContextWarningTest`.
end
