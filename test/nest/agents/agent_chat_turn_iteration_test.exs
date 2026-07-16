defmodule Nest.Agents.AgentChatTurnIterationTest do
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

  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Init
  alias Nest.LLM.MockClient
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
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
        name: "Iteration Test (#{Elixir.System.unique_integer([:positive])})",
        description: "For mid-turn iteration tests",
        system_prompt: "Test prompt.",
        tools: ["read_file", "write_file", "edit", "shell_cmd", "context"],
        modes: %{
          "build" => %{
            "description" => "Test mode",
            "caps" => %{
              "net" => false,
              "fs" => %{"read" => ["/"], "write" => ["/tmp"]}
            }
          }
        }
      })

    vocation.id
  end

  defp start_test_agent do
    vocation_id = programmer_vocation_id()
    agent_name = "test-agent-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Nest.Persistence.insert_agent(%{
        name: agent_name,
        model: %{name: "qwen3.5-plus"},
        vocation_id: vocation_id
      })

    attrs = %{
      name: agent_name,
      model: %{name: "qwen3.5-plus", provider: "model-studio"},
      vocation_id: vocation_id,
      vocation: Init.load_vocation(vocation_id)
    }

    pid = start_supervised!({Agent, attrs})

    # Swap the agent's client to MockClient so any ChatTurn
    # the compaction handler respawns ends up calling
    # MockClient (which returns a canned response without
    # touching the network). The OLD test passed without
    # an LLM hit because the chat turn's pre-refactor
    # sanity check finalized before calling the LLM; the
    # new ChatTurn falls through to the LLM on
    # dispatch_batch, so the swap is what keeps the test
    # hermetic against real HTTP requests.
    :sys.replace_state(pid, fn state ->
      %{state | client_config: %{state.client_config | client: MockClient}}
    end)

    # Re-key the per-agent MockClient queue onto the agent
    # pid so the chat turn's HTTP worker (which threads
    # `opts[:agent_pid]`) finds the test's queue.
    MockClient.start_link(pid)

    pid
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
           name: "context",
           arguments: %{"action" => "compact"}
         }
       ],
       api_logs: []
     }}
  end

  describe ":needs_compaction handler (mid-turn trigger)" do
    test "Agent transitions to :compacting when :needs_compaction arrives" do
      pid = start_test_agent()
      state = :sys.get_state(pid)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.name}")

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

      Agent.terminate(pid)
    end

    test "Agent passes iteration and max_iterations through to the compactor" do
      pid = start_test_agent()
      state = :sys.get_state(pid)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.name}")

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

        # Send compaction_done with the unified
        # `{:tool_call, msg, iter, max}` continuation. The
        # carried `msg` is synthetic — what matters for this
        # test is that the new ChatTurn spawns and runs,
        # producing a chat:status broadcast the test can
        # observe.
        send(
          pid,
          {:compaction_done, "Summary", {:tool_call, synthetic_tool_call_msg(), 25, 30}}
        )

        # The new ChatTurn spawns and runs. With the carried
        # assistant+ToolUse at the tail, the ChatTurn's
        # `pending_tool_calls?/1` returns true and it
        # executes the carried tool call (context.compact,
        # which BatchSizer strips → empty result); then the
        # next iteration falls through to the LLM and the
        # chat turn finalizes with a chat:status broadcast.
        assert_receive {:chat_status, _payload}, 500
      end)

      Agent.terminate(pid)
    end
  end

  describe "mid_turn_entry field lifecycle" do
    test "mid_turn_entry is cleared on successful compaction_done" do
      pid = start_test_agent()
      state = :sys.get_state(pid)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.name}")

      # Pre-seed mid_turn_entry as if a mid-turn
      # compaction is in progress. The new field shape
      # carries the full continuation payload (not just
      # the iteration counters) so a future retry can
      # resume with the same carry-forward semantics.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | mid_turn_entry: %{
                  entry: {:tool_call, synthetic_tool_call_msg(), 7, 30}
                }
            }
        }
      end)

      capture_log(fn ->
        send(
          pid,
          {:compaction_done, "Summary", {:tool_call, synthetic_tool_call_msg(), 7, 30}}
        )

        # Wait for the compactor to finish and the new
        # ChatTurn to spawn. The new ChatTurn iterates
        # (the carried tool_call triggers
        # `execute_pending_tool_calls`, which yields an
        # empty BatchSizer run after the context.compact
        # strip), then falls through to the LLM and
        # finalizes — broadcasting chat:status along the
        # way.
        assert_receive {:chat_status, _payload}, 500
      end)

      state_after = :sys.get_state(pid)
      assert state_after.chat_state.mid_turn_entry == nil

      Agent.terminate(pid)
    end
  end

  describe "retry_compaction branches on mid_turn_entry" do
    test "retry uses mid-turn continuation when mid_turn_entry is set" do
      pid = start_test_agent()
      state = :sys.get_state(pid)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.name}")

      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | status: :compaction_failed,
                mid_turn_entry: %{
                  entry: {:tool_call, synthetic_tool_call_msg(), 12, 30}
                }
            }
        }
      end)

      capture_log(fn ->
        send(pid, :retry_compaction)

        assert_receive {:chat_status, %{status: "compacting"}}, 500
      end)

      Agent.terminate(pid)
    end

    test "retry uses Trigger B path when mid_turn_entry is nil" do
      pid = start_test_agent()
      state = :sys.get_state(pid)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.name}")

      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | status: :compaction_failed,
                pending_user_message: {"Hello", "build"},
                mid_turn_entry: nil
            }
        }
      end)

      capture_log(fn ->
        send(pid, :retry_compaction)

        assert_receive {:chat_status, %{status: "compacting"}}, 500
      end)

      Agent.terminate(pid)
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
      pid = start_test_agent()

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
             %Part.Text{text: "I'll read that file."},
             %Part.ToolUse{
               id: "call_1",
               name: "read_file",
               arguments: %{"path" => "/tmp/example.txt"}
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
          # Pass the carried tool_call_msg directly via the new
          # `ChatTurn.State.continuation/0` shape — bypasses the
          # legacy `normalize_continuation/2` translate so the test
          # is hermetic against any change in that dispatch table.
          send(
            pid,
            {:compaction_done, summary_text, {:tool_call, assistant_with_tool_use, 3, 30}}
          )

          # Drain the agent's mailbox before inspecting state. The
          # compaction handler does the swap, persists/broadcasts,
          # then spawns the new ChatTurn synchronously inside the
          # same `{:noreply, state}` return.
          _ = :sys.get_state(pid)

          # Capture the chat_turn_pid while the new ChatTurn is
          # still alive — it iterates and finalizes promptly once
          # MockClient returns its canned response, after which
          # `state.chat_state.chat_turn_pid` is cleared by
          # `chat_idle`. The state below is read here so the
          # carry-forward assertions can run before that happens.
          chat_turn_pid = :sys.get_state(pid).chat_state.chat_turn_pid

          send(self(), {:chat_turn_pid_captured, chat_turn_pid})
        end)

      assert_receive {:chat_turn_pid_captured, chat_turn_pid}, 1_000
      assert is_pid(chat_turn_pid)

      chat_turn_state = :sys.get_state(chat_turn_pid)

      # The agent's chat_state.messages now ends with the carried-forward
      # assistant+ToolUse, preceded by summary_user. (The system
      # message is in history after the swap — the new design
      # doesn't regenerate it.)
      final_messages = :sys.get_state(pid).chat_state.messages

      assert length(final_messages) == 2,
             "expected [summary_user, assistant+ToolUse]; got #{inspect(final_messages)}"

      assert match?({:user, _}, Enum.at(final_messages, 0))

      # The carried-forward trailing assistant message must carry the
      # original ToolUse parts (the renumbering pass in
      # `Compaction.Lifecycle.swap_messages/3` assigns fresh indices
      # to the whole `new_messages` list, so we compare on shape
      # rather than full struct equality).
      {tail_role, tail_struct} = List.last(final_messages)
      assert tail_role == :assistant

      assert Enum.any?(
               tail_struct.parts,
               &match?(%Part.ToolUse{id: "call_1", name: "read_file"}, &1)
             )

      # The ChatTurn's `entry` is the carried entry itself —
      # the `ChatTurn.State.entry/0` shape — not the legacy
      # `%{kind: :mid_turn, iteration, max_iterations}` map.
      assert chat_turn_state.entry == {:tool_call, assistant_with_tool_use, 3, 30}
      {ctx_tail_role, ctx_tail_struct} = List.last(chat_turn_state.ctx.messages)
      assert ctx_tail_role == :assistant
      assert Enum.any?(ctx_tail_struct.parts, &match?(%Part.ToolUse{id: "call_1"}, &1))

      # Silence the unused-variable warning on `log` — captured so
      # debugging output (if any) lands in the test report.
      _ = log

      Agent.terminate(pid)
    end
  end

  # Regression coverage for the "25% context warning fires on every
  # user message past 25%" bug lives in
  # `Nest.Agents.AgentContextWarningTest`.
end
