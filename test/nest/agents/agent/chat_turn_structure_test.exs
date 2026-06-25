defmodule Nest.Agents.Agent.ChatTurnStructureTest do
  @moduledoc """
  Structural-invariant tests for the ChatTurn + Agent
  architecture. These tests assert properties of the
  codebase that the refactor's plan is supposed to
  guarantee: the State struct is small, dead code is
  gone, the iteration driver is the ChatTurn, the Agent
  is the single source of truth for conversation state.

  A test failure here means a contributor reintroduced
  one of the architectural violations the refactor
  fixed. The tests are simple (file existence, struct
  shape, function exported) but catch a real class of
  regressions that integration tests would not.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatTurn.State

  describe "ChatTurn.State" do
    test "has exactly the expected fields (no Agent state duplication)" do
      expected_fields = [
        :ctx,
        :iteration,
        :max_iterations,
        :force_finalize,
        :active_worker,
        :active_worker_kind,
        :active_message_index,
        :crossed_thresholds
      ]

      actual_fields = State.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()
      sorted_expected = Enum.sort(expected_fields)

      assert actual_fields == sorted_expected,
             "ChatTurn.State fields changed: " <>
               "expected #{inspect(sorted_expected)}, " <>
               "got #{inspect(actual_fields)}"
    end

    test "has 8 fields (largely stateless per the refactor's design intent)" do
      field_count = State.__struct__() |> Map.from_struct() |> map_size()
      assert field_count == 8
    end

    test "does not duplicate Agent conversation state" do
      # These fields were removed during the refactor
      # because they duplicated Agent state (messages,
      # streaming_acc, next_message_index, etc.) or were
      # pure dead code (last_thinking, cancelled).
      forbidden_fields = [
        :agent_pid,
        :messages_snapshot,
        :streaming_acc,
        :last_thinking,
        :cancelled,
        :api_log_sequences
      ]

      struct_keys = State.__struct__() |> Map.from_struct() |> Map.keys()

      for field <- forbidden_fields do
        refute field in struct_keys,
               "ChatTurn.State must not have #{inspect(field)} (Agent-owned state)"
      end
    end
  end

  describe "dead code is gone" do
    test "lib/nest/agents/agent/llm_runner.ex does not exist" do
      refute File.exists?("lib/nest/agents/agent/llm_runner.ex"),
             "LLMRunner was deleted in Commit 1; do not recreate it"
    end

    test "lib/nest/agents/agent/chat_turn/helpers.ex does not exist" do
      refute File.exists?("lib/nest/agents/agent/chat_turn/helpers.ex"),
             "chat_turn/helpers.ex was deleted in Commit 1; " <>
               "the one useful function (maybe_inject_budget_reminder/1) " <>
               "moved inline to chat_turn.ex"
    end

    test "test/nest/agents/agent/chat_turn/helpers_test.exs does not exist" do
      refute File.exists?("test/nest/agents/agent/chat_turn/helpers_test.exs"),
             "helpers_test.exs tested the deleted Helpers module"
    end

    test "Mimic.copy(Nest.Agents.Agent.LLMRunner) is not in test_helper.exs" do
      content = File.read!("test/test_helper.exs")

      refute content =~ "Mimic.copy(Nest.Agents.Agent.LLMRunner)",
             "test_helper.exs must not reference the deleted LLMRunner module"
    end

    test "LLM.Runner.run/2 is the only entry point (no LLMRunner.run/2)" do
      # Check the specific files that previously referenced
      # LLMRunner. We don't recurse lib/ because some
      # references (in doc-comments or tests) are
      # acceptable historical context.
      files_to_check = [
        "lib/nest/agents/agent.ex",
        "lib/nest/agents/agent/chat_turn.ex",
        "lib/nest/agents/agent/chat_turn/http_worker.ex",
        "lib/nest/agents/agent/chat_turn/messages.ex",
        "lib/nest/agents/agent/chat_turn/api_log.ex",
        "lib/nest/agents/agent/chat_pipeline.ex",
        "lib/nest/agents/agent/chat_turn_supervisor.ex",
        "lib/nest/agents/agent/handlers/llm_stream_handler.ex",
        "lib/nest/agents/agent/handlers/compaction_handler.ex",
        "lib/nest/agents/agent/handlers/chat_turn_handler.ex",
        "lib/nest/agents/agent/handlers/stop_handler.ex"
      ]

      for path <- files_to_check do
        if File.exists?(path) do
          content = File.read!(path)

          refute content =~ "LLMRunner.run(",
                 "#{path} must not reference LLMRunner.run/2 (deleted in Commit 1)"
        end
      end
    end
  end

  describe "iteration architecture" do
    test "ChatTurn is the only iteration driver (no LLM.Runner state types in iteration code)" do
      chat_turn = File.read!("lib/nest/agents/agent/chat_turn.ex")

      # The ChatTurn must not import or reference the
      # deleted LLMRunner module's types.
      refute chat_turn =~ "alias Nest.Agents.Agent.LLMRunner"
      refute chat_turn =~ "%LLMRunner.RunContext{"
      refute chat_turn =~ "%LLMRunner.RunState{"
    end

    test "Agent.exposes the Agent contract for ChatTurn" do
      # The ChatTurn queries the Agent for messages and
      # next_message_index. The Agent must expose these.
      agent_content = File.read!("lib/nest/agents/agent.ex")

      assert agent_content =~ "def handle_call(:get_messages,",
             "Agent must expose :get_messages for ChatTurn iteration"

      assert agent_content =~ "def handle_call(:get_next_index,",
             "Agent must expose :get_next_index for api_log keying"
    end
  end

  describe "mid-iteration preflight" do
    test "the iteration step issues a preflight request before each LLM call" do
      # The iteration step is split across three files:
      #
      #   * `ChatTurn.safe_iterate/1` — the driver (in chat_turn.ex)
      #   * `ChatTurn.Iteration.dispatch_preflight/2` — the dispatch
      #   * `ChatTurn.Preflight.run/1` — sends the literal
      #     `{:preflight_request, ...}` to the Agent
      #
      # Any of the three holding the literal proves the
      # structural invariant: the iteration step runs
      # preflight before every LLM call.
      chat_turn = File.read!("lib/nest/agents/agent/chat_turn.ex")
      iteration = File.read!("lib/nest/agents/agent/chat_turn/iteration.ex")
      preflight = File.read!("lib/nest/agents/agent/chat_turn/preflight.ex")

      assert chat_turn =~ "preflight_request" or
               iteration =~ "preflight_request" or
               preflight =~ "preflight_request",
             "the iteration step must issue a preflight_request to the Agent " <>
               "before each LLM call (re-enabled in Commit 5; " <>
               "without it, long tool-call chains can blow the " <>
               "context window without compacting mid-turn)"
    end
  end

  describe "single source of truth for chat:error" do
    test "the HTTP worker does not broadcast chat:error directly" do
      http_worker = File.read!("lib/nest/agents/agent/chat_turn/http_worker.ex")

      # The HTTP worker's on_error callback must NOT call
      # Broadcasts.error directly (that was a double-broadcast
      # bug fixed in Commit 2). The worker only sends
      # {:llm_error, msg} to the Agent; the Agent is the
      # single source of chat:error events.
      refute http_worker =~ "Broadcasts.error(",
             "HTTP worker must not broadcast chat:error directly"
    end

    test "the Agent's llm_error handler is the single source of chat:error" do
      handler = File.read!("lib/nest/agents/agent/handlers/llm_stream_handler.ex")

      assert handler =~ "Broadcasts.error(",
             "Agent's llm_error handler must broadcast chat:error " <>
               "(the single source after Commit 2's fix)"
    end
  end
end
