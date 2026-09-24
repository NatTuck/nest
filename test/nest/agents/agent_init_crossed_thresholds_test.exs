defmodule Nest.Agents.AgentInitCrossedThresholdsTest do
  @moduledoc """
  Restart-safety for context-usage warnings: `Init.seed_from_db/3`
  rebuilds `live.crossed_thresholds` from the persisted notice
  metadata in the active (post-compaction) message segment, so a BEAM
  restart mid-conversation does not re-announce 25/50/75.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.ChatState
  alias Nest.Agents.Agent.Init
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User

  defp state, do: %Agent{chat_state: %ChatState{}, live: %ChatState.Live{}}

  defp system_msg do
    {:system, %System{index: 0, parts: [%Part.Text{text: "sys"}], api_logs: []}}
  end

  defp tagged_notice(index, atom) do
    {:user,
     %User{
       index: index,
       parts: [%Part.Text{text: "Context at #{atom}."}],
       metadata: %{"context_threshold" => Atom.to_string(atom)},
       api_logs: []
     }}
  end

  test "rebuilds crossed_thresholds from stamped notices in the active segment" do
    preloaded = [system_msg(), tagged_notice(1, :p25), tagged_notice(2, :p50)]

    assert Init.seed_from_db(state(), preloaded, -1).live.crossed_thresholds ==
             MapSet.new([:p25, :p50])
  end

  test "excludes notices archived behind the compaction boundary" do
    preloaded = [system_msg(), tagged_notice(1, :p25), tagged_notice(2, :p50)]

    # Boundary at index 1: only index > 1 is active, so :p50 remains
    # announced and :p25 re-arms for the new segment.
    assert Init.seed_from_db(state(), preloaded, 1).live.crossed_thresholds ==
             MapSet.new([:p50])
  end

  test "no preloaded messages leaves the default empty set" do
    assert Init.seed_from_db(state(), [], -1).live.crossed_thresholds == MapSet.new()
  end
end
