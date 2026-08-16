defmodule Nest.Agents.Agent.ChatPipelinePreflightTest do
  @moduledoc """
  Pure unit tests for `Nest.Agents.Agent.ChatPipeline.preflight_decision/2`.

  The function is the single decision point between
  `handle_chat/3` and the rest of the chat pipeline: it
  decides whether the pending chat turn fits the model's
  context window, needs compaction, or cannot compact. It
  dispatches to `Nest.Tokens.PreFlight.check_messages/3`
  with a reserve derived from `state.llm_metrics.context_limit`.

  These tests build minimal Agent structs by hand and call
  `preflight_decision/2` directly. No GenServer, no DB,
  no Mimic — `async: true` is safe and the tests run in
  microseconds.

  `context_limit` is never optional: it is always a positive
  integer in the agent runtime (resolved eagerly at init with
  a 128k `:default` floor). Passing a nil or non-positive
  limit matches no clause and raises, rather than proceeding
  optimistically.
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

  describe "preflight_decision/2 with a nil or non-positive context_limit" do
    test "raises on a nil context_limit instead of proceeding optimistically" do
      state = build_state(%{context_limit: nil, context_limit_source: nil})
      messages = [user_message("hi")]

      assert_raise FunctionClauseError, fn ->
        ChatPipeline.preflight_decision(messages, state)
      end
    end

    test "raises when context_limit_source is :default but limit is nil" do
      state = build_state(%{context_limit: nil, context_limit_source: :default})
      messages = [user_message("hi")]

      assert_raise FunctionClauseError, fn ->
        ChatPipeline.preflight_decision(messages, state)
      end
    end

    test "raises on a non-positive context_limit" do
      state = build_state(%{context_limit: 0, context_limit_source: :config})
      messages = [user_message("hi")]

      assert_raise FunctionClauseError, fn ->
        ChatPipeline.preflight_decision(messages, state)
      end
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
