defmodule Nest.Agents.Agent.TurnStructureTest do
  @moduledoc """
  Structural-invariant tests for the in-process turn architecture.

  These assert properties the refactor is meant to guarantee: the turn
  driver runs inside the Agent (no separate `ChatTurn` process or
  supervisor), the turn working memory is a small sub-struct, worker
  results are ref-validated, and the Agent is the single source of
  conversation state.

  A failure here means a contributor reintroduced one of the
  architectural violations the refactor removed.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatState.Live.Turn

  describe "ChatState.Live.Turn" do
    test "has exactly the expected fields (no Agent state duplication)" do
      expected =
        [
          :active_message_index,
          :active_worker,
          :active_worker_kind,
          :ctx,
          :entry,
          :force_finalize,
          :iteration,
          :max_iterations,
          :pending_notice,
          :worker_ref
        ]
        |> Enum.sort()

      actual = Turn.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()
      assert actual == expected
    end

    test "does not duplicate persisted conversation state" do
      struct_keys = Turn.__struct__() |> Map.from_struct() |> Map.keys()

      for field <- [:messages, :streaming_acc, :next_message_index, :chat_turn_pid] do
        refute field in struct_keys, "Live.Turn must not carry #{inspect(field)}"
      end
    end
  end

  describe "the ChatTurn process is gone" do
    test "the deleted ChatTurn modules do not exist" do
      for path <- [
            "lib/nest/agents/agent/chat_turn.ex",
            "lib/nest/agents/agent/chat_turn/state.ex",
            "lib/nest/agents/agent/chat_turn/iteration.ex",
            "lib/nest/agents/agent/chat_turn/lifecycle.ex",
            "lib/nest/agents/agent/chat_turn/response_handler.ex",
            "lib/nest/agents/agent/chat_turn/notice_injector.ex",
            "lib/nest/agents/agent/chat_turn/http_worker.ex",
            "lib/nest/agents/agent/chat_turn_spawner.ex",
            "lib/nest/agents/agent/chat_turn_supervisor.ex"
          ] do
        refute File.exists?(path), "#{path} was removed in the in-process turn refactor"
      end
    end

    test "the ChatTurnSupervisor is not in the supervision tree" do
      content = File.read!("lib/nest/application.ex")
      refute content =~ "ChatTurnSupervisor"
    end

    test "the Agent routes turn messages to the in-process driver" do
      handlers = File.read!("lib/nest/agents/agent/handlers.ex")
      assert handlers =~ "alias Nest.Agents.Agent.Turn"
      assert handlers =~ "route_for(:iterate), do: {:ok, Turn}"
      assert handlers =~ "{:http_response, _, _}"
      assert handlers =~ "{:tool_results, _, _}"
    end
  end

  describe "worker results are ref-validated" do
    test "the turn driver matches the worker ref and phase before applying a result" do
      turn = File.read!("lib/nest/agents/agent/turn.ex")
      assert turn =~ "worker_ref"
      assert turn =~ "valid_worker?"
    end

    test "workers send ref-tagged results to the Agent" do
      worker = File.read!("lib/nest/agents/agent/turn/http_worker.ex")
      assert worker =~ "{:http_response, ref, response}"

      iteration = File.read!("lib/nest/agents/agent/turn/iteration.ex")
      assert iteration =~ "{:tool_results, ref"
    end
  end

  describe "single source of truth for chat:error" do
    test "the HTTP worker does not broadcast chat:error directly" do
      worker = File.read!("lib/nest/agents/agent/turn/http_worker.ex")
      refute worker =~ "Broadcasts.error("
    end

    test "the Agent's stream handler broadcasts chat:error" do
      handler = File.read!("lib/nest/agents/agent/handlers/llm_stream_handler.ex")
      assert handler =~ "Broadcasts.error("
    end
  end
end
