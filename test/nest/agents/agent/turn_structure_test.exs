defmodule Nest.Agents.Agent.TurnStructureTest do
  @moduledoc """
  Structural "no reintroduction" guards for the in-process turn architecture.

  Both properties here are visible only in the source tree: the live sequence
  has one writer, and the `ChatTurn` modules the refactor deleted stay deleted.
  Behavioural coverage of the turn itself lives in
  `Nest.Agents.Agent.TurnAcceptanceTest`.
  """

  use ExUnit.Case, async: true

  @agent_sources Path.wildcard("lib/nest/agents/agent.ex") ++
                   Path.wildcard("lib/nest/agents/agent/**/*.ex")

  describe "single sequence writer" do
    test "only MessageAppender, Init, and the executor's compaction archive write the live sequence" do
      allowed =
        MapSet.new([
          "lib/nest/agents/agent/message_appender.ex",
          "lib/nest/agents/agent/init.ex",
          "lib/nest/agents/agent/turn/executor.ex"
        ])

      offenders =
        for path <- @agent_sources, sequence_writer?(path), path not in allowed, do: path

      assert offenders == [],
             "unexpected live-sequence writer(s): #{inspect(offenders)}; " <>
               "route the write through MessageAppender instead"
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
  end

  @sequence_write ~r/chat_state:\s*%\{[^}]*(?:\bmessages:|\bnext_message_index:)/s
  defp sequence_writer?(path), do: Regex.match?(@sequence_write, File.read!(path))
end
