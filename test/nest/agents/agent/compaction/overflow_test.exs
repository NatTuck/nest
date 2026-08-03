defmodule Nest.Agents.Agent.Compaction.OverflowTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Compaction.Overflow`.

  Verifies the unified message format shared by
  `chat_pipeline.ex:refuse_compaction/1` (`:cannot_compact`)
  and `trigger.ex:broadcast_reserve_exhausted/1`
  (`:reserve_exhausted`). The two paths used to have
  near-duplicate copies of the message; this test pins the
  unified format so they can't drift again.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Compaction.Overflow

  describe "message/2 (limit, system_prompt)" do
    test "includes limit, system prompt size, and reserve size in tokens" do
      msg = Overflow.message(10_000, String.duplicate("z", 7_000), "start a conversation")

      assert msg =~ "Cannot start a conversation:"
      assert msg =~ "context limit (10000)"
      assert msg =~ "system prompt"
      assert msg =~ "reserved response budget (8192 tokens)"
      assert msg =~ "Use a model with a larger context window"
    end

    test "verb 'compact' produces the compact-pipeline message" do
      msg = Overflow.message(10_000, String.duplicate("z", 7_000), "compact")

      assert msg =~ "Cannot compact:"
      assert msg =~ "context limit (10000)"
      assert msg =~ "reserved response budget (8192 tokens)"
    end

    test "default verb is 'compact' (matches the trigger's :reserve_exhausted case)" do
      msg = Overflow.message(10_000, String.duplicate("z", 7_000))

      assert msg =~ "Cannot compact:"
    end

    test "size of nil system_prompt is 0 (no overflow on the reserve side)" do
      msg = Overflow.message(10_000, nil, "compact")
      assert msg =~ "system prompt (~0 tokens)"
    end
  end

  describe "system_size/1" do
    test "returns the rendered prompt's token count" do
      assert Overflow.system_size(String.duplicate("a", 100)) > 0
    end

    test "an empty prompt returns the per-message overhead" do
      assert Overflow.system_size("") > 0
    end

    test "nil returns 0" do
      assert Overflow.system_size(nil) == 0
    end

    test "size scales with prompt length (sanity check)" do
      small = Overflow.system_size(String.duplicate("a", 100))
      large = Overflow.system_size(String.duplicate("a", 1_000))

      assert large > small
    end
  end

  describe "message/4 reason clauses" do
    test ":system_oversized reports the budget break specifically" do
      msg = Overflow.message(100_000, String.duplicate("z", 30_000), "compact", :system_oversized)

      assert msg =~ "Cannot compact:"
      assert msg =~ "25% safety budget"
      assert msg =~ "100000-token context window"
      refute msg =~ "reserved response budget"
    end

    test ":reserve_exhausted reports the model budget break" do
      msg = Overflow.message(10_000, String.duplicate("z", 7_000), "compact", :reserve_exhausted)

      assert msg =~ "Cannot compact:"
      assert msg =~ "reserved response budget (8192 tokens)"
      refute msg =~ "25% safety budget"
    end
  end
end
