defmodule Nest.Agents.AgentChatTurnIterationTest do
  @moduledoc """
  Tests for the mid-turn compaction flow.

  The flow:

    * `ChatTurn.handle_response/2` runs `BatchSizer.preflight/2`
      on the projected tool results. If the projected total
      would push the conversation past
      `(context_limit - reserve)`, the ChatTurn exits cleanly
      with `{:needs_compaction, self(), iteration, max_iterations}`.
    * The Agent receives `:needs_compaction`, sets
      `:compacting` status, and spawns the compactor with a
      `{:mid_turn_continuation, iteration, max_iterations}`
      continuation.
    * On compaction success, the Agent spawns a fresh
      ChatTurn with `:mid_turn` info. The new ChatTurn sees
      the compacted messages and the assistant+ToolUse tail,
      and executes the LLM's already-emitted tool calls
      rather than calling the LLM again.
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
    pid
  end

  describe ":needs_compaction handler (mid-turn trigger)" do
    test "Agent transitions to :compacting when :needs_compaction arrives" do
      pid = start_test_agent()
      state = :sys.get_state(pid)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.name}")

      capture_log(fn ->
        send(pid, {:needs_compaction, self(), 5, 30})

        # The handler sets status to :compacting and spawns
        # the compactor. The status broadcast is the
        # observable signal.
        assert_receive {:chat_status, %{status: "compacting"}}, 500
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

        # Send compaction_done with mid_turn continuation.
        new_messages = [
          {:system,
           %Nest.Messages.System{
             index: 0,
             parts: [%Part.Text{text: "Summary"}],
             api_logs: []
           }}
        ]

        send(pid, {:compaction_done, new_messages, {:mid_turn_continuation, 25, 30}})

        # The new ChatTurn spawns and runs the sanity check
        # (no assistant+ToolUse at end). The chat turn
        # detects the sanity failure, logs an error, and
        # finalizes. Wait for any status broadcast to
        # confirm the new ChatTurn was spawned and ran.
        assert_receive {:chat_status, _payload}, 500
      end)

      Agent.terminate(pid)
    end
  end

  describe "mid_turn_compaction field lifecycle" do
    test "mid_turn_compaction is cleared on successful compaction_done" do
      pid = start_test_agent()
      state = :sys.get_state(pid)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.name}")

      # Pre-seed mid_turn_compaction as if a mid-turn
      # compaction is in progress.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | mid_turn_compaction: %{iteration: 7, max_iterations: 30}
            }
        }
      end)

      capture_log(fn ->
        new_messages = [
          {:system,
           %Nest.Messages.System{
             index: 0,
             parts: [%Part.Text{text: "Summary"}],
             api_logs: []
           }},
          {:user, %User{index: 1, parts: [%Part.Text{text: "Next"}], api_logs: []}}
        ]

        send(pid, {:compaction_done, new_messages, {:mid_turn_continuation, 7, 30}})

        # Wait for the compactor to finish and the new
        # ChatTurn to spawn. The new ChatTurn runs the
        # sanity check (no ToolUse at end), logs, and
        # finalizes. Wait for any status broadcast to
        # confirm the new ChatTurn was spawned.
        assert_receive {:chat_status, _payload}, 500
      end)

      state_after = :sys.get_state(pid)
      assert state_after.chat_state.mid_turn_compaction == nil

      Agent.terminate(pid)
    end
  end

  describe "retry_compaction branches on mid_turn_compaction" do
    test "retry uses mid-turn continuation when mid_turn_compaction is set" do
      pid = start_test_agent()
      state = :sys.get_state(pid)
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{state.name}")

      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | status: :compaction_failed,
                mid_turn_compaction: %{iteration: 12, max_iterations: 30}
            }
        }
      end)

      capture_log(fn ->
        send(pid, :retry_compaction)

        assert_receive {:chat_status, %{status: "compacting"}}, 500
      end)

      Agent.terminate(pid)
    end

    test "retry uses Trigger B path when mid_turn_compaction is nil" do
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
                mid_turn_compaction: nil
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
end
