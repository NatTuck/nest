defmodule Nest.Tokens.ReserveTest do
  @moduledoc """
  Tests for `Nest.Tokens.Reserve`.

  Pins the formula `max(0.20 × context_limit, 8_192)` across
  the floor/share transition; verifies the function raises on
  contexts that are not positive integers.
  """

  use ExUnit.Case, async: true

  alias Nest.Tokens.Reserve

  describe "compaction_reserve/1" do
    test "returns max(20% of the limit, 8_192)" do
      # Below the floor/share transition (40_960 = 8_192 / 0.20) the flat
      # 8_192 wins. This is the only value that pins the floor itself: at
      # 40_959 and 40_960 a 20% share alone would also round to 8_192.
      assert Reserve.compaction_reserve(32_000) == 8_192

      # At the transition, 40_960 × 0.20 = 8_192.0 exactly, and one token
      # below it 40_959 × 0.20 = 8_191.8 → round → 8_192. The latter pins
      # rounding rather than truncation.
      assert Reserve.compaction_reserve(40_960) == 8_192
      assert Reserve.compaction_reserve(40_959) == 8_192

      # Above the transition the 20% share dominates: 100_000 × 0.20 = 20_000.
      assert Reserve.compaction_reserve(100_000) == 20_000
    end

    test "raises FunctionClauseError when the context is not a positive integer" do
      assert_raise FunctionClauseError, fn -> Reserve.compaction_reserve(0) end
      assert_raise FunctionClauseError, fn -> Reserve.compaction_reserve(-1) end
      assert_raise FunctionClauseError, fn -> Reserve.compaction_reserve(nil) end
      assert_raise FunctionClauseError, fn -> Reserve.compaction_reserve(32_768.0) end
    end
  end
end
