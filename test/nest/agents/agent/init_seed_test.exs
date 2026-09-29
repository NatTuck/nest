defmodule Nest.Agents.AgentInitSeedTest do
  @moduledoc """
  `Init.seed_from_db/4`'s compaction-count derivation.

  The collapsed-history card renders the running compaction count, which
  must survive a restart without loading the archive. A clone's preload
  is its parent's *visible* messages only, so the inherited marker rows
  are not in it; the count arrives as the fourth argument instead.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.ChatState
  alias Nest.Agents.Agent.Init
  alias Nest.Messages.Compaction
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User

  defp state, do: %Agent{chat_state: %ChatState{}, live: %ChatState.Live{}}

  defp system_msg(index \\ 0) do
    {:system, %System{index: index, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp user_msg(index) do
    {:user, %User{index: index, parts: [%Part.Text{text: "u"}], api_logs: []}}
  end

  defp marker(index) do
    {:compaction, %Compaction{index: index, archived_count: index + 1}}
  end

  test "counts marker rows at or below the boundary" do
    preloaded = [system_msg(), marker(1), system_msg(2), user_msg(3)]
    seeded = Init.seed_from_db(state(), preloaded, 1, 0)
    assert seeded.chat_state.compaction_count == 1
  end

  test "ignores marker rows above the boundary" do
    preloaded = [system_msg(), marker(1), system_msg(2), marker(3), user_msg(4)]
    seeded = Init.seed_from_db(state(), preloaded, 2, 0)
    assert seeded.chat_state.compaction_count == 1
  end

  test "falls back to the inherited count when the preload has no markers" do
    # A clone's preload is the parent's visible messages (no marker row),
    # but it inherits the parent's boundary and compaction count.
    preloaded = [system_msg(5), user_msg(6)]
    seeded = Init.seed_from_db(state(), preloaded, 4, 2)
    assert seeded.chat_state.compaction_count == 2
  end

  test "recomputed markers win when they exceed the inherited count" do
    preloaded = [system_msg(), marker(1), system_msg(2), marker(3), user_msg(4)]
    seeded = Init.seed_from_db(state(), preloaded, 3, 1)
    assert seeded.chat_state.compaction_count == 2
  end

  test "empty preload leaves the state untouched" do
    assert Init.seed_from_db(state(), [], -1, 3).chat_state.compaction_count == 0
  end
end
