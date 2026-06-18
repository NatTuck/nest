defmodule Nest.Tokens.PreFlightTest do
  @moduledoc """
  Tests for `Nest.Tokens.PreFlight`.

  Covers:
  - All three decision outcomes (:fits, :needs_compaction, :no_limit_known)
  - Boundary cases (exactly at the limit, one over)
  - Custom reserve values
  - Convenience wrapper with message lists
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.PreFlight

  describe "check/3" do
    test "no_limit_known when context_limit is nil" do
      assert PreFlight.check(1000, nil) == :no_limit_known
      assert PreFlight.check(1000, nil, 5000) == :no_limit_known
    end

    test ":fits when projected total is well within the limit" do
      # 1000 used + 8192 reserve = 9192 < 32_768 context
      assert PreFlight.check(1000, 32_768) == :fits
    end

    test ":fits when projected total is exactly at the limit" do
      # used + reserve == context_limit
      # 23_576 + 8192 = 31_768 ≤ 32_768 — fits
      assert PreFlight.check(23_576, 32_768) == :fits
    end

    test ":needs_compaction when projected total overflows the limit" do
      # 30_000 + 8192 = 38_192 > 32_768 — overflows
      assert PreFlight.check(30_000, 32_768) == :needs_compaction
    end

    test ":needs_compaction when projected total is exactly over the limit" do
      # 24_577 + 8192 = 32_769 > 32_768 — overflows by 1
      assert PreFlight.check(24_577, 32_768) == :needs_compaction
    end

    test "custom reserve is respected" do
      # With a 16k reserve, 18_000 used would overflow a 32k context
      assert PreFlight.check(18_000, 32_768, 16_384) == :needs_compaction

      # With a 4k reserve, 18_000 used fits a 32k context
      assert PreFlight.check(18_000, 32_768, 4_096) == :fits
    end

    test "zero estimated size fits within any limit" do
      assert PreFlight.check(0, 32_768) == :fits
      assert PreFlight.check(0, 1_000, 100) == :fits
    end

    test "default reserve is 8192" do
      # 24_576 + 8192 = 32_768 → fits
      assert PreFlight.check(24_576, 32_768) == :fits
      # 24_577 + 8192 = 32_769 → needs compaction
      assert PreFlight.check(24_577, 32_768) == :needs_compaction
    end
  end

  describe "check_messages/3" do
    test "estimates the message list and applies the check" do
      messages = [
        {:system, %System{content: "You are helpful"}},
        {:user, %User{content: "Hello"}}
      ]

      # With a 32k context, two short messages fit
      assert PreFlight.check_messages(messages, 32_768) == :fits
    end

    test "no_limit_known when context_limit is nil" do
      messages = [{:user, %User{content: "Hello"}}]
      assert PreFlight.check_messages(messages, nil) == :no_limit_known
    end

    test "empty message list with reasonable context is :fits" do
      assert PreFlight.check_messages([], 32_768) == :fits
    end

    test "a huge message list triggers :needs_compaction" do
      # Repeated identical chars compress to ~1 token per ~4 bytes
      # under BPE, so 100k chars isn't actually that big in tokens.
      # Use a 4 MB string to reliably overflow a 32k context.
      huge = String.duplicate("a ", 2_000_000)
      messages = [{:user, %User{content: huge}}]
      # 4M chars at ~3-4 tokens per char on alternating content,
      # plus 20% safety, plus 8192 reserve — way over 32k.
      assert PreFlight.check_messages(messages, 32_768) == :needs_compaction
    end
  end
end
