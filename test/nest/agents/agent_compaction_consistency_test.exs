defmodule Nest.Agents.AgentCompactionConsistencyTest do
  @moduledoc """
  Pins the output contract of `Nest.Tokens.Compactor.compact/3` —
  the structural guarantee the agent's compaction handler
  (`Nest.Agents.Agent.Handlers.CompactionHandler.regenerate_for_compaction/2`)
  relies on.

  Contract (under the new "no special rules" design):

    * `{:ok, summary_text, run_response}` on success. The compactor
      returns the LLM's response verbatim; it does NOT wrap,
      rename, or otherwise reshape the response. The caller
      (`Nest.Agents.Agent.Compaction`) records the response as a
      regular assistant message on the agent's message list and
      uses `summary_text` to build the post-compaction user
      message.
    * `{:ok, :passthrough}` for `:too_short` input (empty,
      system-only, system + single user, no head to summarize).
      No LLM call was made; the caller skips the swap.
    * `{:error, :llm_returned_empty}` for an empty LLM response,
      or `{:error, reason}` for any other transport error.

  The compactor's role is now narrow: build a single LLM call
  with the prior conversation + `[mode: compact]` suffix, return
  the response. Message construction, history append, and the
  post-compaction user message are all the caller's job.

  See `notes/properly-handle-summary-messages-and-openai-think.md`
  for the design.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.Compactor

  describe "output contract" do
    test "success returns {:ok, summary_text, run_response} — compactor does not wrap" do
      messages = build_messages()

      assert {:ok, "head summary text", %RunResponse{text: "head summary text"}} =
               Compactor.compact(messages, 100_000, llm_call("head summary text"))
    end

    test "Pass 2 (tail-summary) is removed — compactor runs once" do
      # The pre-v1 design produced `[system, head_summary,
      # last_user, tail_summary]` for over-budget compactions.
      # v1 runs the LLM exactly once and trusts the summary to
      # cover everything. No recent slice to summarize into a
      # Pass 2 — the LLM's single summary includes everything.
      messages = build_messages()

      test_pid = self()

      capture_llm = fn _messages, _remaining_tokens, _optional_guidance ->
        send(test_pid, :llm_called)
        {:ok, %RunResponse{text: "single pass summary", stop_reason: "stop"}}
      end

      assert {:ok, "single pass summary", _response} =
               Compactor.compact(messages, 100_000, capture_llm)

      # Exactly one LLM call.
      assert_received :llm_called
      refute_received :llm_called
    end

    test "too-short input returns {:ok, :passthrough} — no LLM call, no wrapping" do
      [system] = build_messages() |> Enum.take(1)

      assert Compactor.compact([system], 100_000, llm_call("unused")) == {:ok, :passthrough}
    end

    test "empty LLM response surfaces as {:error, :llm_returned_empty}" do
      # The compactor does not synthesize a placeholder summary
      # when the LLM returns an empty string. The failure is
      # surfaced through the `{:error, :llm_returned_empty}`
      # contract so the agent's compaction handler can set
      # `:compaction_failed` status and broadcast `chat:error`.
      messages = build_messages()

      assert {:error, :llm_returned_empty} =
               Compactor.compact(messages, 100_000, llm_call(""))
    end

    test "the LLM call receives the agent's full prior conversation (KV cache reuse)" do
      messages = build_messages()

      test_pid = self()

      capture_llm = fn llm_messages, _remaining_tokens, _optional_guidance ->
        send(test_pid, {:llm_called, llm_messages})
        {:ok, %RunResponse{text: "summary", stop_reason: "stop"}}
      end

      {:ok, _text, _response} =
        Compactor.compact(messages, 100_000, capture_llm)

      assert_received {:llm_called, input}
      assert length(input) == length(messages)
      assert input == messages
    end
  end

  ## Helpers

  defp build_messages do
    [
      {:system, %System{index: 0, parts: [%Part.Text{text: "You are helpful"}]}},
      {:user, %User{index: 1, parts: [%Part.Text{text: "Q1"}]}},
      {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "A1"}]}}
    ]
  end

  # Three-arity LLM callback matching the new compactor contract.
  # The compactor passes (messages, remaining_tokens,
  # optional_guidance); tests ignore the second/third args.
  # Returns `{:ok, %RunResponse{text: text, stop_reason: "stop"}}`
  # so the compactor's downstream extraction sees a populated
  # `.text`.
  defp llm_call(text) do
    fn _messages, _remaining_tokens, _optional_guidance ->
      {:ok, %RunResponse{text: text, stop_reason: "stop"}}
    end
  end
end
