defmodule Nest.Agents.Agent.ChatTurn.ContextReminderTest do
  @moduledoc """
  Tests for the mid-iteration context-usage reminder logic.

  These are unit tests of `ContextReminder.highest_unannounced/3`,
  `ContextReminder.format/3`, and `ContextReminder.build_message/3`.
  The ChatTurn wiring (call to `maybe_inject_context_warning/2`
  in `iterate/1`, reset on compaction) follows the same pattern
  as the existing tool-iteration budget reminder and is covered
  by the integration tests in `agent_system_messages_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatTurn.ContextReminder
  alias Nest.Messages.System

  describe "highest_unannounced/3" do
    test "returns nil when usage is well under 25%" do
      assert ContextReminder.highest_unannounced(1_000, 200_000, MapSet.new()) == nil
    end

    test "returns :p25 when usage crosses 25%" do
      assert ContextReminder.highest_unannounced(50_001, 200_000, MapSet.new()) == :p25
    end

    test "returns :p50 when usage crosses 50%" do
      assert ContextReminder.highest_unannounced(100_001, 200_000, MapSet.new()) == :p50
    end

    test "returns :p75 when usage crosses 75%" do
      assert ContextReminder.highest_unannounced(150_001, 200_000, MapSet.new()) == :p75
    end

    test "returns only the highest crossed threshold (not 25+50+75)" do
      # If a fresh turn starts at 80% usage, fire 75% — not all three.
      assert ContextReminder.highest_unannounced(160_000, 200_000, MapSet.new()) == :p75
    end

    test "returns nil when threshold was already announced" do
      crossed = MapSet.new([:p25])
      assert ContextReminder.highest_unannounced(150_001, 200_000, crossed) == :p75
    end

    test "returns nil when all thresholds already announced" do
      crossed = MapSet.new([:p25, :p50, :p75])
      assert ContextReminder.highest_unannounced(200_000, 200_000, crossed) == nil
    end

    test "returns nil when limit is zero or negative (defensive)" do
      assert ContextReminder.highest_unannounced(100, 0, MapSet.new()) == nil
      assert ContextReminder.highest_unannounced(100, -1, MapSet.new()) == nil
    end
  end

  describe "format/3" do
    test ":p25 includes the percentage, used, and limit" do
      text = ContextReminder.format(:p25, 50_000, 200_000)
      assert text =~ "25%"
      assert text =~ "50000"
      assert text =~ "200000"
    end

    test ":p50 includes the percentage, used, and limit" do
      text = ContextReminder.format(:p50, 100_000, 200_000)
      assert text =~ "50%"
      assert text =~ "100000"
      assert text =~ "200000"
    end

    test ":p75 includes the percentage, used, limit, and a context tool recommendation" do
      text = ContextReminder.format(:p75, 150_000, 200_000)
      assert text =~ "75%"
      assert text =~ "150000"
      assert text =~ "200000"
      assert text =~ "context"
      assert text =~ "compact"
    end
  end

  describe "build_message/3" do
    test "returns a {:system, %System{}} tuple with the formatted content" do
      assert {:system, %System{content: content, timestamp: %DateTime{}}} =
               ContextReminder.build_message(:p50, 100_000, 200_000)

      assert content =~ "50%"
      assert content =~ "100000"
      assert content =~ "200000"
    end
  end
end
