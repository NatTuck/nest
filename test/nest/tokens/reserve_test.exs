defmodule Nest.Tokens.ReserveTest do
  @moduledoc """
  Tests for `Nest.Tokens.Reserve`.

  Pins the formula `max(0.20 × context_limit, 8_192)` across
  the floor/share transition; verifies the function errors on
  non-positive contexts; verifies monotonicity across small,
  medium, and large limits.
  """

  use ExUnit.Case, async: true

  alias Nest.Tokens.Reserve

  describe "response_budget/1" do
    test "returns the floor (8_192) at small contexts" do
      # Below the floor/share transition (40_960 = 8_192 / 0.20),
      # the flat 8_192 wins.

      assert Reserve.response_budget(32_000) == 8_192
      assert Reserve.response_budget(40_960) == 8_192
    end

    test "returns 20% at large contexts where share dominates" do
      assert Reserve.response_budget(100_000) == 20_000
      assert Reserve.response_budget(200_000) == 40_000
    end

    test "boundary: exact floor at limit == 40_960" do
      # 40_960 × 0.20 = 8_192.0 exactly. Either way, result is 8_192.
      assert Reserve.response_budget(40_960) == 8_192
    end

    test "floor wins for 1 token below the transition" do
      # 40_959 × 0.20 = 8_191.8 → round → 8_192. Floor still wins
      # on a tie (max picks the larger).
      assert Reserve.response_budget(40_959) == 8_192
    end

    test "share wins above the transition" do
      # 40_961 × 0.20 = 8_192.2 → round → 8_192. Either way, result
      # is 8_192 (within rounding).
      assert Reserve.response_budget(40_961) == 8_192

      # 50_000 × 0.20 = 10_000 — share strictly dominates.
      assert Reserve.response_budget(50_000) == 10_000
    end

    test "monotonic across the formula's transition" do
      # Walking limit up by 1k steps, the result is monotonically
      # non-decreasing.
      results =
        for limit <- 1_000..100_000//1_000 do
          Reserve.response_budget(limit)
        end

      assert results == Enum.sort(results)
    end

    test "result is always a positive integer" do
      for limit <- [1, 100, 1_000, 32_768, 100_000, 999_999] do
        assert is_integer(Reserve.response_budget(limit))
        assert Reserve.response_budget(limit) >= 1
      end
    end

    test "raises FunctionClauseError on non-positive contexts" do
      assert_raise FunctionClauseError, fn -> Reserve.response_budget(0) end
      assert_raise FunctionClauseError, fn -> Reserve.response_budget(-1) end
    end

    test "raises FunctionClauseError on non-integer contexts" do
      assert_raise FunctionClauseError, fn -> Reserve.response_budget(nil) end
      assert_raise FunctionClauseError, fn -> Reserve.response_budget(32_768.0) end
    end
  end
end
