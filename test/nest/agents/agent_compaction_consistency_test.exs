defmodule Nest.Agents.AgentCompactionConsistencyTest do
  @moduledoc """
  Pins the output contract of `Nest.Tokens.Compactor.compact/3` —
  the structural guarantee the agent's compaction handler
  (`Nest.Agents.Agent.Handlers.CompactionHandler.regenerate_for_compaction/2`)
  relies on.
  Contract: the compactor's `new_messages` always starts with a
  `{:system, _}` message on the `{:ok, _}` branch. The `:too_short`
  branch returns the input unchanged (the agent's
  `state.chat_state.messages` always starts with a system message).
  The pass-1 branch prepends the original system message and
  folds the entire conversation (including the last user message
  and its responses) into a single summary at position 1.
  Recent-slice preservation is gone — at small contexts a single
  `shell_cmd` result can consume half the window on its own.

  Note: the compactor returns the raw LLM summary text (no
  "Summary of earlier conversation:" wrapping). The agent's
  compaction handler adds the user-visible prefix when it
  re-encodes the summary as a user message.

  See `notes/token-reserve-simplification.md` for the design.
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Tokens.Compactor

  describe "output contract" do
    test "new_messages always starts with the original system message" do
      messages = build_messages()

      assert {:ok, result} =
               Compactor.compact(
                 messages,
                 100_000,
                 llm_call("head summary text")
               )

      assert [{:system, %System{}} | _] = result
    end

    test "head summary is wrapped as {:system, _} at position 1 (raw LLM text)" do
      messages = build_messages()

      assert {:ok, result} =
               Compactor.compact(
                 messages,
                 100_000,
                 llm_call("head summary text")
               )

      # Position 0 is the original system; position 1 is the
      # head summary wrapped as `{:system, _}`. The compactor
      # stores the raw LLM text — the agent's handler adds the
      # user-visible "Summary of earlier conversation:" prefix
      # when it re-encodes this as a user message.
      assert [
               {:system, %System{parts: [%Part.Text{text: position0_text}]}},
               {:system, %System{parts: [%Part.Text{text: position1_text}]}} | _
             ] = result

      assert position0_text == "You are helpful"
      assert position1_text == "head summary text"
    end

    test "the entire conversation folds into one summary (no recent slice preserved)" do
      messages = build_messages()

      assert {:ok, result} =
               Compactor.compact(
                 messages,
                 100_000,
                 llm_call("head summary")
               )

      # Old design produced [system, head_summary, last_user, ...].
      # New design trusts the LLM with the full fold — output is
      # exactly [system, summary]. The last user message and its
      # responses are captured in the LLM's summary text rather
      # than kept verbatim.
      assert length(result) == 2
      assert {:system, %System{parts: [%Part.Text{text: "You are helpful"}]}} = Enum.at(result, 0)
      assert {:system, %System{parts: [%Part.Text{text: "head summary"}]}} = Enum.at(result, 1)
    end

    test "Pass 2 (tail-summary) is removed — compactor runs once" do
      # The pre-v1 design produced `[system, head_summary,
      # last_user, tail_summary]` for over-budget compactions.
      # v1 runs the LLM exactly once and trusts the summary to
      # cover everything. No recent slice to summarize into a
      # Pass 2 — the LLM's single summary includes everything.
      messages = build_messages()

      test_pid = self()

      capture_llm =
        fn _messages, _remaining_tokens, _optional_guidance ->
          send(test_pid, :llm_called)
          {:ok, "single pass summary"}
        end

      assert {:ok, _result} =
               Compactor.compact(messages, 100_000, capture_llm)

      # Exactly one LLM call.
      assert_received :llm_called
      refute_received :llm_called
    end

    test "too-short input returns {:ok, [system]} unchanged" do
      [system] = build_messages() |> Enum.take(1)

      assert {:ok, [result]} =
               Compactor.compact([system], 100_000, llm_call("unused"))

      assert result == system
      assert [{:system, %System{}}] = [result]
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
  end

  ## Helpers

  defp build_messages do
    alias Nest.Messages.Assistant
    alias Nest.Messages.User

    [
      {:system, %System{index: 0, parts: [%Part.Text{text: "You are helpful"}]}},
      {:user, %User{index: 1, parts: [%Part.Text{text: "First question"}]}},
      {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "First answer"}]}},
      {:user, %User{index: 3, parts: [%Part.Text{text: "Second question"}]}},
      {:assistant, %Assistant{index: 4, parts: [%Part.Text{text: "Second answer"}]}}
    ]
  end

  # Three-arity LLM callback matching the new compactor contract.
  # The compactor passes (messages, remaining_tokens,
  # optional_guidance); tests ignore the second/third args.
  defp llm_call(text) do
    fn _messages, _remaining_tokens, _optional_guidance -> {:ok, text} end
  end
end
