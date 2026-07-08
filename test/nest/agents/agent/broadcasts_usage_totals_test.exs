defmodule Nest.Agents.Agent.Broadcasts.UsageTotalsTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Broadcasts.merge_usage_totals/2`
  and `empty_usage_totals/0`.

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
  shape and the merge's per-call / session discipline.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Broadcasts

  describe "empty_usage_totals/0" do
    test "returns the full shape with all fields initialized to 0" do
      totals = Broadcasts.empty_usage_totals()

      # Per-call (overwrite)
      assert totals.input_tokens == 0
      assert totals.cache_read_input_tokens == 0
      assert totals.cache_creation_input_tokens == 0
      assert totals.context_input_tokens == 0
      assert totals.last_output == 0

      # Session (sum)
      assert totals.output_tokens == 0
      assert totals.total_input_tokens == 0
      assert totals.total_cache_read_input_tokens == 0
      assert totals.total_cache_creation_input_tokens == 0
      assert totals.total_tokens == 0
      assert totals.reasoning_tokens == 0
    end
  end

  describe "merge_usage_totals/2" do
    test "a nil usage payload is a no-op" do
      current = Broadcasts.empty_usage_totals()
      assert Broadcasts.merge_usage_totals(current, nil) == current
    end

    test "per-call fields overwrite on a fresh call" do
      current = Broadcasts.empty_usage_totals()

      next =
        Broadcasts.merge_usage_totals(current, %{
          input_tokens: 100,
          cache_read_input_tokens: 50,
          cache_creation_input_tokens: 10,
          output_tokens: 25,
          total_tokens: 175,
          reasoning_tokens: 5
        })

      assert next.input_tokens == 100
      assert next.cache_read_input_tokens == 50
      assert next.cache_creation_input_tokens == 10
      assert next.last_output == 25
      # `context_input_tokens` is left at the current value
      # (0 for a fresh agent). The status_payload broadcasts
      # the real value computed from the messages list.
      assert next.context_input_tokens == 0
    end

    test "session fields sum across calls" do
      current =
        Broadcasts.empty_usage_totals()
        |> Broadcasts.merge_usage_totals(%{
          input_tokens: 100,
          output_tokens: 25,
          total_tokens: 125,
          reasoning_tokens: 5
        })

      next =
        Broadcasts.merge_usage_totals(current, %{
          input_tokens: 200,
          cache_read_input_tokens: 80,
          output_tokens: 30,
          total_tokens: 310,
          reasoning_tokens: 8
        })

      assert next.total_input_tokens == 300
      assert next.total_cache_read_input_tokens == 80
      assert next.output_tokens == 55
      assert next.total_tokens == 435
      assert next.reasoning_tokens == 13
    end

    test "a subsequent call overwrites the per-call fields but keeps the session totals" do
      # The first call sets everything. The second call is
      # smaller — per-call fields should reflect the smaller
      # call, but session totals should be the SUM of both.
      current =
        Broadcasts.empty_usage_totals()
        |> Broadcasts.merge_usage_totals(%{
          input_tokens: 1000,
          output_tokens: 200,
          total_tokens: 1200,
          reasoning_tokens: 50
        })

      next =
        Broadcasts.merge_usage_totals(current, %{
          input_tokens: 50,
          cache_read_input_tokens: 30,
          output_tokens: 5,
          total_tokens: 85,
          reasoning_tokens: 0
        })

      # Per-call: overwritten by the smaller second call.
      assert next.input_tokens == 50
      assert next.cache_read_input_tokens == 30
      assert next.last_output == 5

      # Session: cumulative sum.
      assert next.total_input_tokens == 1050
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

      assert next.input_tokens == 100
      assert next.cache_read_input_tokens == 0
      assert next.cache_creation_input_tokens == 0
      # Session cumulative cache totals stay at 0.
      assert next.total_cache_read_input_tokens == 0
    end

    test "a missing input_tokens leaves the per-call fields untouched" do
      # A nil `input_tokens` is the signal that this isn't a
      # usage-only update — the merge should leave the per-call
      # fields alone and not zero them out. Session fields still
      # sum the available data.
      current =
        Broadcasts.empty_usage_totals()
        |> Broadcasts.merge_usage_totals(%{
          input_tokens: 100,
          output_tokens: 25,
          total_tokens: 125
        })

      # Now a usage map without `input_tokens` — should be a
      # no-op on the per-call fields, but `output_tokens` still
      # adds.
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
