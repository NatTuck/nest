defmodule Nest.Agents.Agent.ChatTurn.ContextReminderTest do
  @moduledoc """
  Tests for the mid-iteration context-usage reminder logic.

  These are unit tests of `ContextReminder.highest_unannounced/3`,
  `ContextReminder.format/3`, and `ContextReminder.build_message/3`.
  The ChatTurn wiring (call to `inject_context_warning/2`
  in `iterate/1`, set persisted to the Agent via
  `{:set_crossed_thresholds, set}`, set cleared on successful
  compaction in `Compaction.ResultHandler.handle_success/3`)
  is covered by the regression tests in
  `agent_chat_turn_iteration_test.exs`.

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
    test "returns a {:user, %User{}} tuple with the formatted content" do
      assert {:user,
              %User{parts: [%Nest.Messages.Part.Text{text: content}], timestamp: %DateTime{}}} =
               ContextReminder.build_message(:p50, 80_000, @limit)

      assert content =~ "50%"
      assert content =~ "80000"
      assert content =~ "#{@working_budget}"
    end
  end

  describe "build_message/4" do
    test "returns a {:user, %User{}} tuple with the formatted content" do
      config = %ClientConfig{}

      assert {:user,
              %User{parts: [%Nest.Messages.Part.Text{text: content}], timestamp: %DateTime{}}} =
               ContextReminder.build_message(:p50, 80_000, @limit, config)

      assert content =~ "50%"
      assert content =~ "80000"
    end

    test "accepts nil config" do
      assert {:user,
              %User{parts: [%Nest.Messages.Part.Text{text: content}], timestamp: %DateTime{}}} =
               ContextReminder.build_message(:p75, 120_000, @limit, nil)

      assert content =~ "75%"
      assert content =~ "120000"
      assert content =~ "context"
    end
  end

  describe "notice_text/1" do
    test "returns short notice for :p25" do
      assert ContextReminder.notice_text(:p25) == "Context at 25%."
    end

    test "returns short notice for :p50" do
      assert ContextReminder.notice_text(:p50) == "Context at 50%."
    end

    test "returns short notice for :p75 with compact recommendation" do
      assert ContextReminder.notice_text(:p75) =~ "compact"
    end
  end

  describe "ack_text_for/1" do
    test "returns ack for :p25" do
      assert ContextReminder.ack_text_for(:p25) == "Okay, that's plenty of space."
    end

    test "returns ack for :p50" do
      assert ContextReminder.ack_text_for(:p50) == "Okay, I should consider conserving tokens."
    end

    test "returns ack for :p75 with compact recommendation" do
      assert ContextReminder.ack_text_for(:p75) =~ "compact"
    end
  end

  describe "build_user_notice/2" do
    test "returns a {:user, %User{}} with the given text" do
      {:user, %User{parts: [%Nest.Messages.Part.Text{text: "hello"}]}} =
        ContextReminder.build_user_notice("hello", %ClientConfig{})
    end
  end

  describe "spec/3" do
    test "returns nil when usage is well under 25% of the working budget" do
      assert ContextReminder.spec(1_000, @limit, MapSet.new()) == nil
    end

    test "returns a :context spec with 'Context?' attention and full format text for :p25" do
      spec = ContextReminder.spec(40_001, @limit, MapSet.new())
      assert spec.kind == :context
      assert spec.attention == "Context?"
      assert spec.notice =~ "25%"
      assert spec.notice =~ "40001"
    end

    test "returns a :context spec for :p50" do
      spec = ContextReminder.spec(80_001, @limit, MapSet.new())
      assert spec.kind == :context
      assert spec.attention == "Context?"
      assert spec.notice =~ "50%"
    end

    test "returns a :context spec for :p75 with compact recommendation" do
      spec = ContextReminder.spec(120_001, @limit, MapSet.new())
      assert spec.kind == :context
      assert spec.attention == "Context?"
      assert spec.notice =~ "75%"
      assert spec.notice =~ "compact"
    end

    test "returns nil when the only crossed threshold was already announced (no higher threshold crossed)" do
      # Usage is past 25% but not 50% or 75%. With :p25 in
      # the crossed set, no new threshold fires.
      crossed = MapSet.new([:p25])
      assert ContextReminder.spec(50_000, @limit, crossed) == nil
    end

    test "still returns a spec when a higher unannounced threshold is crossed" do
      # Usage is past 75%. :p25 is announced, but :p75 is not.
      # The spec fires for :p75.
      crossed = MapSet.new([:p25])
      spec = ContextReminder.spec(120_001, @limit, crossed)
      assert spec.kind == :context
      assert spec.notice =~ "75%"
    end

    test "returns nil when all thresholds already announced" do
      crossed = MapSet.new([:p25, :p50, :p75])
      assert ContextReminder.spec(160_000, @limit, crossed) == nil
    end

    test "returns nil when limit is zero or negative (defensive)" do
      assert ContextReminder.spec(100, 0, MapSet.new()) == nil
      assert ContextReminder.spec(100, -1, MapSet.new()) == nil
    end
  end
end
