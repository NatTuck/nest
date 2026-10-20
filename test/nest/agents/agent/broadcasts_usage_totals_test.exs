defmodule Nest.Agents.Agent.Broadcasts.UsageTotalsTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Broadcasts.Usage`: the
  `merge_usage_totals/2` discipline and the `context_usage_map/4`
  chip fields.

  The merge runs on every `:llm_usage` event the GenServer
  receives. It maintains two axes of state:

    * **Per-call (overwrite)** — the most recent LLM call's
      values, used by the cost estimate's per-call math.
    * **Session (sum)** — cumulative values across every call,
      used by the cost estimate.

  The `context_input_tokens` field is no longer derived here.
  It is computed at broadcast time by
  `Broadcasts.status_payload/1` via
  `Nest.Tokens.ConversationSize.size/1`, which combines the
  real-valued `tokens` from prior LLM responses (set by
  `LLMStreamHandler.mark_last_message_tokens/2`) with the
  estimator's projection of any suffix. Tests for the field's
  value live in `ConversationSizeTest`; this file pins the
  merge's per-call / session discipline.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Broadcasts.Usage

  describe "context_usage_map/4" do
    test "passes the running totals through and adds the in-flight projection" do
      direct = %{input_tokens: 100, total_input_tokens: 500}

      usage = Usage.context_usage_map(direct, [], 512_000, 999)

      assert usage.input_tokens == 100
      assert usage.total_input_tokens == 500
      assert usage.projected_context_input_tokens == 999
    end

    test "working_budget is nil for an unusable limit and floored at 1 for a tiny one" do
      assert Usage.context_usage_map(%{}, [], nil, nil).working_budget == nil
      assert Usage.context_usage_map(%{}, [], 0, nil).working_budget == nil
      # 100 - compaction_reserve(100) is negative, so the floor applies.
      assert Usage.context_usage_map(%{}, [], 100, nil).working_budget == 1
    end
  end

  describe "merge_usage_totals/2" do
    test "a new call overwrites the per-call fields and sums the session totals" do
      # The first call sets everything. The second call is
      # smaller — per-call fields should reflect the smaller
      # call, but session totals should be the SUM of both.
      current =
        Broadcasts.empty_usage_totals()
        |> Broadcasts.merge_usage_totals(%{
          input_tokens: 1000,
          cache_read_input_tokens: 60,
          cache_creation_input_tokens: 40,
          output_tokens: 200,
          total_tokens: 1200,
          reasoning_tokens: 50
        })

      next =
        Broadcasts.merge_usage_totals(current, %{
          input_tokens: 50,
          cache_read_input_tokens: 30,
          cache_creation_input_tokens: 10,
          output_tokens: 5,
          total_tokens: 85,
          reasoning_tokens: 0
        })

      # Per-call: overwritten by the smaller second call.
      assert next.input_tokens == 50
      assert next.cache_read_input_tokens == 30
      assert next.cache_creation_input_tokens == 10
      assert next.last_output == 5

      # Session: cumulative sum.
      assert next.total_input_tokens == 1050
      assert next.total_cache_read_input_tokens == 90
      assert next.total_cache_creation_input_tokens == 50
      assert next.output_tokens == 205
      assert next.total_tokens == 1285
      assert next.reasoning_tokens == 50
    end

    test "cache fields missing from the usage payload default to 0" do
      # Backward-compat: older clients don't send cache fields.
      current = Broadcasts.empty_usage_totals()

      next =
        Broadcasts.merge_usage_totals(current, %{
          input_tokens: 100,
          output_tokens: 25,
          total_tokens: 125
        })

      # The non-cache field landed, so the zeroes below are the
      # payload's missing fields rather than an unmerged map.
      assert next.input_tokens == 100
      assert next.cache_read_input_tokens == 0
      assert next.cache_creation_input_tokens == 0
      # Session cumulative cache totals stay at 0.
      assert next.total_cache_read_input_tokens == 0
    end

    test "a missing input_tokens leaves the per-call fields untouched" do
      # A usage payload without `input_tokens` is a usage-only
      # update: the per-call fields keep their values rather than
      # being zeroed out, and the session fields still sum
      # whatever the payload does carry.
      current =
        Broadcasts.empty_usage_totals()
        |> Broadcasts.merge_usage_totals(%{
          input_tokens: 100,
          output_tokens: 25,
          total_tokens: 125
        })

      next =
        Broadcasts.merge_usage_totals(current, %{
          output_tokens: 10,
          total_tokens: 10
        })

      assert next.input_tokens == 100
      assert next.last_output == 25
      # The output STILL sums (session sum semantics).
      assert next.output_tokens == 35
    end

    test "context_input_tokens is not derived here (computed by status_payload instead)" do
      # Even with non-zero per-call fields, merge_usage_totals
      # leaves `context_input_tokens` at its prior value (0 for
      # a fresh agent). The status broadcast computes it from
      # the messages list via ConversationSize.size/1.
      current = Broadcasts.empty_usage_totals()

      next =
        Broadcasts.merge_usage_totals(current, %{
          input_tokens: 100,
          cache_read_input_tokens: 50,
          cache_creation_input_tokens: 25
        })

      assert next.context_input_tokens == 0
    end
  end
end
