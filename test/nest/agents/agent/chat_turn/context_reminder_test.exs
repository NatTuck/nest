defmodule Nest.Agents.Agent.ChatTurn.ContextReminderTest do
  @moduledoc """
  Tests for the mid-iteration context-usage reminder logic.

  These are unit tests of `ContextReminder.highest_unannounced/3`,
  `ContextReminder.format/3`, and `ContextReminder.build_message/3`.
  The ChatTurn wiring (call to `maybe_inject_context_warning/2`
  in `iterate/1`, reset on compaction) follows the same pattern
  as the existing tool-iteration budget reminder and is covered
  by the integration tests in `agent_system_messages_test.exs`.

  ## Reserve-aware math

  The thresholds measure against the working token budget
  (`context_limit - reserve`), not the raw context_limit.
  For a 200k-context model with the standard reserve
  (`max(0.20 × limit, 8192) = 40_000`), the working budget is
  160_000 tokens. So:

      25% → fires at `40_000` used (was `50_001` of 200k)
      50% → fires at `80_000` used (was `100_001` of 200k)
      75% → fires at `120_000` used (was `150_001` of 200k)

  See `Nest.Tokens.Reserve` for the formula.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.ChatTurn.ContextReminder
  alias Nest.LLM.ClientConfig
  alias Nest.Messages.System
  alias Nest.Messages.User

  # A 200k-limit model with the standard 40k reserve has a
  # 160k working budget, so the threshold numbers below all
  # correspond to working-budget percentages.
  @limit 200_000
  @working_budget 160_000

  describe "highest_unannounced/3" do
    test "returns nil when usage is well under 25% of the working budget" do
      # 1_000 / 160_000 ≈ 0.6%, well below 25%.
      assert ContextReminder.highest_unannounced(1_000, @limit, MapSet.new()) == nil
    end

    test "returns :p25 when usage crosses 25% of the working budget" do
      # 40_001 / 160_000 ≈ 25%, just above threshold.
      assert ContextReminder.highest_unannounced(40_001, @limit, MapSet.new()) == :p25
    end

    test "returns :p50 when usage crosses 50% of the working budget" do
      # 80_001 / 160_000 ≈ 50%.
      assert ContextReminder.highest_unannounced(80_001, @limit, MapSet.new()) == :p50
    end

    test "returns :p75 when usage crosses 75% of the working budget" do
      # 120_001 / 160_000 ≈ 75%.
      assert ContextReminder.highest_unannounced(120_001, @limit, MapSet.new()) == :p75
    end

    test "fires earlier with reserve than without (regression for Bug 2-era calc)" do
      # The new math: effective = max(1, 200_000 - 40_000) = 160_000.
      # With reserve subtracted, 40_000 used is 25% of the
      # working budget — fires :p25.
      # Pre-fix, 40_000 / 200_000 = 20% — would NOT fire any
      # threshold yet. The new behavior fires earlier, which is
      # the correct guidance for the LLM (the reserve will be
      # consumed by the compactor's response).
      assert ContextReminder.highest_unannounced(40_000, @limit, MapSet.new()) == :p25
    end

    test "returns only the highest crossed threshold (not 25+50+75)" do
      # If a fresh turn starts at 80% of working budget
      # (128_000/160_000), fire 75% — not all three.
      assert ContextReminder.highest_unannounced(128_000, @limit, MapSet.new()) == :p75
    end

    test "returns nil when threshold was already announced" do
      crossed = MapSet.new([:p25])
      assert ContextReminder.highest_unannounced(120_001, @limit, crossed) == :p75
    end

    test "returns nil when all thresholds already announced" do
      crossed = MapSet.new([:p25, :p50, :p75])
      assert ContextReminder.highest_unannounced(160_000, @limit, crossed) == nil
    end

    test "returns nil when limit is zero or negative (defensive)" do
      assert ContextReminder.highest_unannounced(100, 0, MapSet.new()) == nil
      assert ContextReminder.highest_unannounced(100, -1, MapSet.new()) == nil
    end
  end

  describe "format/3" do
    test ":p25 includes the percentage, used, and working budget" do
      text = ContextReminder.format(:p25, 40_000, @limit)
      assert text =~ "25%"
      assert text =~ "40000"
      assert text =~ "#{@working_budget}"
    end

    test ":p50 includes the percentage, used, and working budget" do
      text = ContextReminder.format(:p50, 80_000, @limit)
      assert text =~ "50%"
      assert text =~ "80000"
      assert text =~ "#{@working_budget}"
    end

    test ":p75 includes the percentage, used, working budget, and a context tool recommendation" do
      text = ContextReminder.format(:p75, 120_000, @limit)
      assert text =~ "75%"
      assert text =~ "120000"
      assert text =~ "#{@working_budget}"
      assert text =~ "context"
      assert text =~ "compact"
    end

    test "format text uses the spec'd shape ('~used of ~effective token budget')" do
      used = 1234
      expected_effective = @working_budget

      text = ContextReminder.format(:p50, used, @limit)

      assert text ==
               "Context usage is now at 50% (~#{used} of ~#{expected_effective} token budget)."
    end
  end

  describe "build_message/3" do
    test "returns a {:system, %System{}} tuple with the formatted content" do
      assert {:system,
              %System{parts: [%Nest.Messages.Part.Text{text: content}], timestamp: %DateTime{}}} =
               ContextReminder.build_message(:p50, 80_000, @limit)

      assert content =~ "50%"
      assert content =~ "80000"
      assert content =~ "#{@working_budget}"
    end
  end

  describe "build_message/4 with rewrite off" do
    test "returns a {:system, %System{}} tuple (default path unchanged)" do
      config = %ClientConfig{rewrite_late_system_messages: false}

      assert {:system,
              %System{parts: [%Nest.Messages.Part.Text{text: content}], timestamp: %DateTime{}}} =
               ContextReminder.build_message(:p50, 80_000, @limit, config)

      assert content =~ "50%"
      assert content =~ "80000"
    end

    test "accepts nil config (treats as default off)" do
      assert {:system,
              %System{parts: [%Nest.Messages.Part.Text{text: content}], timestamp: %DateTime{}}} =
               ContextReminder.build_message(:p75, 120_000, @limit, nil)

      assert content =~ "75%"
      assert content =~ "120000"
      assert content =~ "context"
    end
  end

  describe "build_message/4 with rewrite on" do
    test "returns a {:user, %User{}} tuple with [System notice: …] wrap" do
      config = %ClientConfig{rewrite_late_system_messages: true}

      assert {:user,
              %User{parts: [%Nest.Messages.Part.Text{text: content}], timestamp: %DateTime{}}} =
               ContextReminder.build_message(:p50, 80_000, @limit, config)

      assert content =~ "[System notice: "
      assert content =~ "]"
      assert content =~ "50%"
      assert content =~ "80000"
      assert content =~ "#{@working_budget}"
    end

    test "the bracket wraps the full threshold text including the 75% compact recommendation" do
      config = %ClientConfig{rewrite_late_system_messages: true}

      assert {:user,
              %User{parts: [%Nest.Messages.Part.Text{text: content}], timestamp: %DateTime{}}} =
               ContextReminder.build_message(:p75, 120_000, @limit, config)

      assert content =~ "[System notice: Context usage is now at 75%"
      assert content =~ "context"
      assert content =~ "compact"
    end
  end
end
