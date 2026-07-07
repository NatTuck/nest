defmodule Nest.Agents.AgentCompactionFailureTest do
  @moduledoc """
  Tests for the compaction-ownership redesign's failure path
  (TODO 2 + TODO 3 in `notes/extract-compaction-and-resumable-chat-turn.md`):

    * `Compaction.spawn/5`'s failure path sends
      `{:compaction_failed, reason, continuation}` to the Agent
      (not `{:compaction_done, original_messages, _}`, which
      silently masked failures pre-fix).
    * The Agent's `CompactionHandler.compaction_failed/3` handler:
      1. Sets `chat_state.status` to `:compaction_failed`.
      2. Broadcasts `chat:status: "compaction_failed"` so the UI
         can show the retry banner.
      3. Broadcasts `chat:error` with a `compactionError: true` marker
         so the frontend routes to `setCompactionError` (not
         `setAgentError`).
      4. Preserves `state.chat_state.pending_user_message` so a
         `chat:retry-compaction` re-attaches the user's pending
         message to the next compaction attempt.
    * `chat:retry-compaction` (TODO 5 + TODO 7) re-runs the
      compactor only when the agent is in `:compaction_failed`
      status; otherwise the handler is a no-op (logs a warning).

  `async: false` for the same reason as the other compaction tests
  (sandbox connection walks `$callers` at the agent boundary,
  async tests lose ownership).
  """

  use Nest.DataCase, async: false

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Init
  alias Nest.LLM.MockClient
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
        name: "Compaction Failure Test (#{Elixir.System.unique_integer([:positive])})",
        description: "For compaction-failure tests",
        system_prompt: "Test prompt.",
        tools: ["read_file", "write_file", "edit", "shell_cmd", "context"],
        modes: %{
          "chat" => %{
            "description" => "Test mode",
            "caps" => %{
              "net" => false,
              "fs" => %{"read" => ["/"], "write" => []}
            }
          }
        }
      })

    vocation.id
  end

  describe "CompactionHandler.compaction_failed/3" do
    test "sets status to :compaction_failed and broadcasts chat:status" do
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

      # Subscriber that picks up `chat:status` + `chat:error`
      # broadcasts the Agent emits during failure handling.
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_name}")

      # Pre-seed a pending user message so the test pins the
      # preservation behavior (TODO 4 contract).
      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | pending_user_message: {"trigger compaction", "chat"}
            }
        }
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          # Simulate a compaction failure from Trigger B (the
          # chat-continuation path). Reason: `:llm_returned_empty`.
          send(
            pid,
            {:compaction_failed, :llm_returned_empty, {:chat_continuation, :pending}}
          )

          # The Agent transitions to :compaction_failed and broadcasts
          # chat:status with status="compaction_failed".
          assert_receive {:chat_status, %{status: "compaction_failed"}}, 500
        end)

      # The handler logs the reason + agent name at warning level
      # and emits a chat:error at error level (captured via
      # Broadcasts.compaction_error/3).
      assert log =~ "Compaction failed"
      assert log =~ "agent=#{agent_name}"
      assert log =~ "llm_returned_empty"
      assert log =~ "chat:error"

      # The pending_user_message field is preserved across the
      # failure so a future retry can re-attach it.
      state_after = :sys.get_state(pid, 500)
      assert state_after.chat_state.status == :compaction_failed
      assert state_after.chat_state.pending_user_message == {"trigger compaction", "chat"}

      Agent.terminate(pid)
    end

    test "broadcasts chat:error with compactionError: true marker" do
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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_name}")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            pid,
            {:compaction_failed, :llm_returned_empty, {:chat_continuation, :pending}}
          )

          # The `chat:error` payload carries `compactionError: true`
          # so the JS frontend can route to `setCompactionError`
          # (which stores the text on the cache for the banner)
          # instead of `setAgentError` (which would flip the
          # connection-level status to "error").
          assert_receive {:chat_error, %{content: _, compactionError: true}}, 500
        end)

      # The handler's chat:error broadcast is also logged at error
      # level via Broadcasts.compaction_error/3. Assert the marker
      # and the reason reach the server log.
      assert log =~ "chat:error"
      assert log =~ "LLM returned empty summary"

      Agent.terminate(pid)
    end

    test "log line includes the reason for debugging" do
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

      log =
        capture_log(fn ->
          send(pid, {:compaction_failed, :timeout, {:chat_continuation, :pending}})
          # Wait for the agent to process the message before
          # capture_log returns, so the log line is captured.
          _ = :sys.get_state(pid, 500)
        end)

      assert log =~ "Compaction failed"
      assert log =~ "timeout"

      Agent.terminate(pid)
    end
  end

  describe "CompactionHandler.retry_compaction/1" do
    test "re-runs the compactor when status is :compaction_failed" do
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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_name}")

      # Place the agent in :compaction_failed with a preserved
      # pending_user_message.
      :sys.replace_state(pid, fn state ->
        %{
          state
          | chat_state: %{
              state.chat_state
              | status: :compaction_failed,
                pending_user_message: {"trigger retry", "chat"}
            }
        }
      end)

      # The retry re-enters task_compaction_request/3, which sets
      # status to :compacting and spawns the compactor. The
      # MockClient returns a random text response by default; the
      # compactor will then send {:compaction_done, ...} back.
      # But for this test we only care that the handler accepted
      # the retry and transitioned to :compacting.
      send(pid, :retry_compaction)

      assert_receive {:chat_status, %{status: "compacting"}}, 500

      Agent.terminate(pid)
    end

    test "is a no-op when status is not :compaction_failed" do
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
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{agent_name}")

      # Agent is in :idle. Retry should be a no-op (logs a warning,
      # does NOT spawn the compactor).
      log =
        capture_log(fn ->
          send(pid, :retry_compaction)
          # Wait for the GenServer to drain the :retry_compaction
          # message before we inspect the log. `:sys.get_state`
          # blocks until the GenServer has processed all pending
          # messages; the handler logs before returning.
          _ = :sys.get_state(pid, 500)
        end)

      assert log =~ "retry_compaction ignored"
      assert log =~ ":idle"

      # The status didn't change to :compacting.
      state_after = :sys.get_state(pid, 500)
      assert state_after.chat_state.status == :idle

      Agent.terminate(pid)
    end
  end
end
