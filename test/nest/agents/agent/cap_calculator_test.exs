defmodule Nest.Agents.Agent.CapCalculatorTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.CapCalculator`'s window reporting.

  `usable_window/1` exists so callers that only need to know *whether* a cap
  applies do not have to handle a raise and a legal zero separately. That
  contract is what these pin: a spent window is `:none`, not an error, and a
  context missing `:messages` is `:none`, not a `KeyError`.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.CapCalculator

  describe "usable_window/1" do
    test "answers a live, spent, or absent window" do
      # 100_000 leaves an 80_000-token content budget (the reserve is 20_000),
      # and a context carrying no `:messages` still has one: the docstring sells
      # this as the safe call for a loosely-shaped context, so it must not raise
      # merely because the key is absent.
      assert CapCalculator.usable_window(%{context_limit: 100_000}) == {:ok, 80_000}

      # 100 cannot hold the 8_192-token reserve, so the window is spent. That is
      # a legal zero, not an error — `usable_remaining/1` returns it without
      # raising, and this reports it as `:none` rather than `{:ok, 0}`.
      assert CapCalculator.usable_window(%{context_limit: 100}) == :none

      # No positive limit at all: the case `usable_remaining/1` does raise on.
      assert CapCalculator.usable_window(%{}) == :none
      assert CapCalculator.usable_window(%{context_limit: nil}) == :none
      assert CapCalculator.usable_window(nil) == :none
    end
  end
end
