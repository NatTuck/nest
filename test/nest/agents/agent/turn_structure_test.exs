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

  alias Nest.Agents.Agent.Machine.Work

  # Every Agent-owned source file, for the single-writer scans below.
  @agent_sources Path.wildcard("lib/nest/agents/agent.ex") ++
                   Path.wildcard("lib/nest/agents/agent/**/*.ex")

  describe "Machine.Work" do
    test "does not duplicate persisted conversation state" do
      struct_keys = Work.__struct__() |> Map.from_struct() |> Map.keys()

      for field <- [:messages, :streaming_acc, :next_message_index, :chat_turn_pid] do
        refute field in struct_keys, "Machine.Work must not carry #{inspect(field)}"
      end
    end
  end

  describe "single sequence writer" do
    test "the Agent's append entry points delegate to MessageAppender" do
      agent = File.read!("lib/nest/agents/agent.ex")
      assert agent =~ ~r/defdelegate __append_message__\([^\n]*MessageAppender/
      assert agent =~ ~r/defdelegate __append_messages__\([^\n]*MessageAppender/
    end

    test "only MessageAppender, Init, and the compaction archive write the live sequence" do
      # The canonical live sequence (`chat_state.messages` +
      # `next_message_index`) is stamped and written only through
      # `MessageAppender`. `Init` seeds it once from the persisted rows on
      # restore; `Compaction.ResultHandler.archive_active_segment/1` clears
      # the in-memory list whose rows already exist at their committed
      # indices (the compacted segment is re-appended through
      # `MessageAppender`). It never stamps a new index.
      allowed =
        MapSet.new([
          "lib/nest/agents/agent/message_appender.ex",
          "lib/nest/agents/agent/init.ex",
          "lib/nest/agents/agent/compaction/result_handler.ex"
        ])

      offenders =
        for path <- @agent_sources, sequence_writer?(path), path not in allowed, do: path

      assert offenders == [],
             "unexpected live-sequence writer(s): #{inspect(offenders)}; " <>
               "route the write through MessageAppender instead"
    end
  end

  describe "single status authority" do
    test "Broadcasts.status_payload derives via Machine.status_for/1" do
      body = function_body(File.read!("lib/nest/agents/agent/broadcasts.ex"), "status_payload")
      assert body =~ "Machine.status_for(state.live.machine)"
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

  # True when the file writes `chat_state.messages` or
  # `next_message_index` through a `chat_state: %{...}` update.
  @sequence_write ~r/chat_state:\s*%\{[^}]*(?:\bmessages:|\bnext_message_index:)/s
  defp sequence_writer?(path), do: Regex.match?(@sequence_write, File.read!(path))

  # The source of a zero-arg public/private function, from its `def` line to
  # its closing `  end`. Used to prove where observable status is derived.
  defp function_body(source, name) do
    case Regex.run(~r/defp #{name}\(.*?\n  end\n/s, source) do
      [body] -> body
      _ -> flunk("could not find defp #{name} in source")
    end
  end
end
