defmodule Nest.Agents.Agent.ChatPipelinePreflightTest do
  @moduledoc """
  Pure unit tests for `Nest.Agents.Agent.ChatPipeline.preflight_decision/2`.

  The function is the single decision point between
  `handle_chat/3` and the rest of the chat pipeline: it
  decides whether the pending chat turn fits the model's
  context window, needs compaction, cannot compact, or has
  no limit known. It dispatches to
  `Nest.Tokens.PreFlight.check_messages/3` with a reserve
  derived from `state.llm_metrics.context_limit`.

  These tests build minimal Agent structs by hand and call
  `preflight_decision/2` directly. No GenServer, no DB,
  no Mimic — `async: true` is safe and the tests run in
  microseconds.

  Regression: prior to the nil-safe guard in
  `preflight_decision/2`, `context_limit: nil` reached
  `Reserve.response_budget/1`, which has no clause for nil
  and crashed the GenServer with a `FunctionClauseError`.
  The first test pins the no-crash behaviour; the second
  pins the integer-limit path to guard against regressions
  in the new guard.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.LlmMetrics
  alias Nest.Messages.Part
  alias Nest.Messages.User

  defp build_state(%{context_limit: limit, context_limit_source: source}) do
    %Agent{llm_metrics: %LlmMetrics{context_limit: limit, context_limit_source: source}}
  end

  defp user_message(text) do
    {:user, %User{parts: [%Part.Text{text: text}]}}
  end

  describe "preflight_decision/2 with a nil context_limit" do
    test "returns :no_limit_known instead of crashing on Reserve.response_budget(nil)" do
      # Models the realistic "all three layers returned nil"
      # case (no per-model static config, no cache entry, no
      # provider default). Before the nil-safe guard, this
      # raised FunctionClauseError from
      # `Nest.Tokens.Reserve.response_budget(nil)`.
      state = build_state(%{context_limit: nil, context_limit_source: nil})
      messages = [user_message("hi")]

      assert ChatPipeline.preflight_decision(messages, state) == :no_limit_known
    end

    test "returns :no_limit_known when context_limit_source is :default but limit is nil" do
      # Belt-and-suspenders: pin that a non-nil source tag
      # with a nil limit still routes to the no-limit path.
      state = build_state(%{context_limit: nil, context_limit_source: :default})
      messages = [user_message("hi")]

      assert ChatPipeline.preflight_decision(messages, state) == :no_limit_known
    end
  end

  describe "preflight_decision/2 with a positive-integer context_limit" do
    test "delegates to PreFlight.check_messages/3 with the scaled reserve" do
      # With a 32_768 context_limit and a single short user
      # message, the projected total (estimated tokens + the
      # scaled 8_192 reserve floor) fits comfortably. This
      # pins the integer-limit guard path and guards against
      # regressions where the guard accidentally swallows
      # valid integer limits.
      state = build_state(%{context_limit: 32_768, context_limit_source: :config})
      messages = [user_message("hi")]

      assert ChatPipeline.preflight_decision(messages, state) == :fits
    end
  end
end
