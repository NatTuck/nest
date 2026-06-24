defmodule Nest.Tokens.CostTest do
  @moduledoc """
  Tests for `Nest.Tokens.Cost.estimate/1`.

  The cost formula is mirrored on the client side in
  `assets/js/utils/cost.js`; both should be updated together.
  The hardcoded rates are user-specified ($1/M input, $4/M
  output, $0.25/M cached input) — verify they match the
  `assert` lines below whenever the rates are changed.
  """

  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias Nest.Tokens.Cost

  describe "estimate/1" do
    test "zero usage totals returns zero cost" do
      assert D.equal?(Cost.estimate(%{}), D.new(0))
    end

    test "ignores non-map input" do
      assert D.equal?(Cost.estimate(nil), D.new(0))
      assert D.equal?(Cost.estimate("not a map"), D.new(0))
    end

    test "one million input tokens at $1/M = $1" do
      cost = Cost.estimate(%{total_input_tokens: 1_000_000})
      assert D.equal?(cost, D.new("1.00"))
    end

    test "one million output tokens at $4/M = $4" do
      cost = Cost.estimate(%{output_tokens: 1_000_000})
      assert D.equal?(cost, D.new("4.00"))
    end

    test "one million cached input tokens at $0.25/M = $0.25" do
      cost = Cost.estimate(%{total_cache_read_input_tokens: 1_000_000})
      assert D.equal?(cost, D.new("0.25"))
    end

    test "sums all three components for a mixed session" do
      # 1M input @ $1 + 1M cached @ $0.25 + 1M output @ $4 = $5.25
      cost =
        Cost.estimate(%{
          total_input_tokens: 1_000_000,
          total_cache_read_input_tokens: 1_000_000,
          output_tokens: 1_000_000
        })

      assert D.equal?(cost, D.new("5.25"))
    end

    test "treats missing fields as zero" do
      assert D.equal?(
               Cost.estimate(%{total_input_tokens: 500_000}),
               D.new("0.50")
             )
    end

    test "treats nil field values as zero" do
      assert D.equal?(
               Cost.estimate(%{
                 total_input_tokens: nil,
                 output_tokens: nil,
                 total_cache_read_input_tokens: nil
               }),
               D.new(0)
             )
    end

    test "reasoning tokens are included via output_tokens (no separate term)" do
      # The cost module reads `output_tokens`, which already
      # includes `reasoning_tokens` per the providers' wire
      # formats. Verify a session with a large reasoning component
      # costs the same as a session with the same total
      # `output_tokens` and no explicit `reasoning_tokens`.
      with_reasoning =
        Cost.estimate(%{output_tokens: 1_000_000, reasoning_tokens: 800_000})

      without_reasoning =
        Cost.estimate(%{output_tokens: 1_000_000, reasoning_tokens: 0})

      assert D.equal?(with_reasoning, without_reasoning)
      assert D.equal?(with_reasoning, D.new("4.00"))
    end

    test "ignores per-call fields (input_tokens, cache_read_input_tokens)" do
      # The cost module uses the cumulative session fields, not
      # the per-call overwrite fields. Per-call fields in the
      # input map should not be picked up.
      cost =
        Cost.estimate(%{
          input_tokens: 1_000_000,
          cache_read_input_tokens: 1_000_000,
          cache_creation_input_tokens: 1_000_000
        })

      assert D.equal?(cost, D.new(0))
    end
  end
end
