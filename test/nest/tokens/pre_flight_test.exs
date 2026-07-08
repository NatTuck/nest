defmodule Nest.Tokens.PreFlightTest do
  @moduledoc """
  Tests for `Nest.Tokens.PreFlight`.

  Covers:
  - All four decision outcomes (:fits, :needs_compaction, :cannot_compact, :no_limit_known)
  - Boundary cases (exactly at the limit, one over)
  - Custom reserve values
  - Convenience wrapper with message lists
  - :cannot_compact when the system prompt alone exceeds the limit
  - :cannot_compact when there is no conversation head to summarize
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.Estimator
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
        {:system, %System{parts: [%Part.Text{text: "You are helpful"}]}},
        {:user, %User{parts: [%Part.Text{text: "Hello"}]}}
      ]

      # With a 32k context, two short messages fit
      assert PreFlight.check_messages(messages, 32_768) == :fits
    end

    test "no_limit_known when context_limit is nil" do
      messages = [{:user, %User{parts: [%Part.Text{text: "Hello"}]}}]
      assert PreFlight.check_messages(messages, nil) == :no_limit_known
    end

    test "empty message list with reasonable context is :fits" do
      assert PreFlight.check_messages([], 32_768) == :fits
    end

    test "a huge message list triggers :needs_compaction when there is a summarizable head" do
      # Repeated identical chars compress to ~1 token per ~4 bytes
      # under BPE, so a huge single user message would be
      # `:cannot_compact` (the compactor's `:too_short` branch
      # would no-op it). To trigger `:needs_compaction` we need
      # a *summarizable head* — older messages between the
      # system prompt and the current user turn.
      huge = String.duplicate("a ", 2_000_000)
      sys = {:system, %System{parts: [%Part.Text{text: "You are helpful."}]}}
      old_user = {:user, %User{parts: [%Part.Text{text: "earlier"}]}}

      assistant =
        {:assistant, %Assistant{parts: [%Part.Text{text: huge}]}}

      new_user = {:user, %User{parts: [%Part.Text{text: "now"}]}}
      messages = [sys, old_user, assistant, new_user]

      # 4M chars at ~3-4 tokens per char on alternating content,
      # plus 20% safety, plus 8192 reserve — way over 32k. The
      # head is summarizable (old_user + assistant), so
      # `:needs_compaction` is correct.
      assert PreFlight.check_messages(messages, 32_768) == :needs_compaction
    end

    test ":cannot_compact when system prompt alone exceeds (context_limit - reserve)" do
      # The system prompt alone is too big to fit even with
      # the full reserve; compaction cannot reduce it because
      # the system prompt is never summarized away.
      huge_system_text = String.duplicate("a ", 30_000)
      sys = {:system, %System{parts: [%Part.Text{text: huge_system_text}]}}
      user = {:user, %User{parts: [%Part.Text{text: "hi"}]}}

      # 30k chars of "a " is ~15k raw tokens, ~18k with safety
      # multiplier + overhead. That alone exceeds (32k - 8192).
      assert PreFlight.check_messages([sys, user], 32_768) == :cannot_compact
    end

    test ":cannot_compact on the first user message when system + user + reserve > limit" do
      # The realistic scenario from the API log: a moderate
      # system prompt (~8400 estimated tokens) + a short user
      # message + the 8192 reserve overflow a 10000-token context.
      # Compaction would return `:too_short` because there's no
      # conversation history between the system and the user.
      sys_text = String.duplicate("z", 7_000)
      sys = {:system, %System{parts: [%Part.Text{text: sys_text}]}}
      user = {:user, %User{parts: [%Part.Text{text: "What do we do?"}]}}

      assert PreFlight.check_messages([sys, user], 10_000) == :cannot_compact
    end

    test ":cannot_compact when a single huge user message has no system prompt" do
      # Edge case: a `[user]` list with no system message.
      # The compactor's `split_messages/1` returns `:too_short`
      # because there's no user anchor at index >= 1 (or no
      # system before the user). Compaction cannot help.
      huge = String.duplicate("a ", 2_000_000)
      messages = [{:user, %User{parts: [%Part.Text{text: huge}]}}]
      assert PreFlight.check_messages(messages, 32_768) == :cannot_compact
    end

    test ":cannot_compact on the `[system, user]` shape regardless of size" do
      # The empty-head shape is what blocks compaction, not
      # the absolute size. Even with a generous context, a
      # `[system, user]` conversation cannot be compacted —
      # the compactor's `:too_short` branch returns it
      # unchanged. Verify the shape-based detection works
      # independently of the size math.
      sys = {:system, %System{parts: [%Part.Text{text: "You are helpful."}]}}
      user = {:user, %User{parts: [%Part.Text{text: "Hi"}]}}
      messages = [sys, user]

      # Pick a limit so small that even a no-op conversation
      # doesn't fit; the preflight should still recognize
      # `:cannot_compact` (shape-based), not `:needs_compaction`.
      base_size = Estimator.estimate_messages(messages)
      # one token short
      limit = base_size + 8_192 - 1

      assert PreFlight.check_messages(messages, limit, 8_192) == :cannot_compact
    end

    test ":needs_compaction when conversation has a real head (compaction would help)" do
      # With messages between system and the last user, compaction
      # CAN help by summarizing the head. The preflight must
      # return `:needs_compaction`, not `:cannot_compact`.
      #
      # Use a moderately-sized head and a tiny context_limit so
      # the projected total clearly overflows without making
      # the tiktoken estimate take forever.
      sys = {:system, %System{parts: [%Part.Text{text: "You are helpful."}]}}
      old_user = {:user, %User{parts: [%Part.Text{text: "earlier question"}]}}
      assistant_text = String.duplicate("ab ", 4_000)

      assistant =
        {:assistant, %Assistant{parts: [%Part.Text{text: assistant_text}]}}

      new_user = {:user, %User{parts: [%Part.Text{text: "new question"}]}}
      messages = [sys, old_user, assistant, new_user]

      # The shape is `[system, old_user, assistant, new_user]`
      # — head is `[old_user, assistant]`, summarizable. Pick
      # a context_limit that overflows when reserve is added.
      projected = Estimator.estimate_messages(messages)
      limit = projected + 8_192 - 100

      assert PreFlight.check_messages(messages, limit, 8_192) == :needs_compaction
    end
  end
end
