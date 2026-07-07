defmodule Nest.Agents.AgentCompactionConsistencyTest do
  @moduledoc """
  Pins the output contract of `Nest.Tokens.Compactor.compact/3` —
  the structural guarantee the agent's compaction handler
  (`Nest.Agents.Agent.Handlers.CompactionHandler.regenerate_for_compaction/2`)
  relies on.

  Contract: the compactor's `new_messages` always starts with a
  `{:system, _}` message. The `:too_short` branch returns the input
  unchanged (the agent's `state.chat_state.messages` always starts
  with a system message). The other branches explicitly prepend
  the original system message. Violations are bugs in the
  compactor; the handler pattern-matches the invariant and
  raises loudly if it's broken.

  Note: per the compaction-ownership redesign (TODO 1), the
  compactor no longer wraps the LLM's summary text with
  "Summary of earlier conversation:" / "Summary of recent work:"
  prefixes — those are added by the agent's compaction handler when
  it re-encodes the summary as a user message. The compactor returns
  the raw LLM text. Empty LLM responses are surfaced as
  `{:error, :llm_returned_empty}` rather than as a placeholder
  summary.

  See `notes/extract-compaction-and-resumable-chat-turn.md` for the
  design.
  """
  use ExUnit.Case, async: true

  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.Compactor

  describe "output contract" do
    test "new_messages always starts with the original system message" do
      messages = build_messages()

      assert {:ok, result} =
               Compactor.compact(messages, 100_000, fn _ -> {:ok, "head summary text"} end)

      assert [{:system, %System{}} | _] = result
    end

    test "head summary is wrapped as {:system, _} at position 1 (raw LLM text)" do
      messages = build_messages()

      assert {:ok, result} =
               Compactor.compact(messages, 100_000, fn _ -> {:ok, "head summary text"} end)

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

    test "last user and its responses are preserved at the tail" do
      messages = build_messages()

      assert {:ok, result} =
               Compactor.compact(messages, 100_000, fn _ -> {:ok, "head summary"} end)

      # Position 2 is the last user; the responses after it
      # (the assistant turn that came after "Second question")
      # follow at positions 3+.
      assert {:user, %User{parts: [%Part.Text{text: "Second question"}]}} =
               Enum.at(result, 2)

      assert {:assistant, %Assistant{parts: [%Part.Text{text: "Second answer"}]}} =
               Enum.at(result, 3)
    end

    test "tail-summary branch produces [system, head_summary, last_user, tail_summary]" do
      # Drive the large-context branch by passing a small
      # context_limit. The LLM is called twice (head then tail);
      # both responses are wrapped as {:system, _} per the contract.
      messages = build_messages()

      llm_call = fn _ -> {:ok, "the summary"} end

      assert {:ok, result} = Compactor.compact(messages, 10, llm_call)

      # Position 0: original system. Position 1: head summary.
      # Position 2: last user. Position 3: tail summary.
      assert length(result) == 4

      assert {:system, %System{}} = Enum.at(result, 0)
      assert {:system, %System{parts: [%Part.Text{text: p1_text}]}} = Enum.at(result, 1)
      assert p1_text == "the summary"
      assert {:user, %User{}} = Enum.at(result, 2)
      assert {:system, %System{parts: [%Part.Text{text: p3_text}]}} = Enum.at(result, 3)
      assert p3_text == "the summary"
    end

    test "too-short input returns {:ok, [system]} unchanged" do
      # Single-element list (just the system message). The
      # compactor returns it under the new {:ok, _} shape; the
      # contract still holds because the input starts with system.
      [system] = build_messages() |> Enum.take(1)

      assert {:ok, [result]} = Compactor.compact([system], 100_000, fn _ -> {:ok, "unused"} end)

      assert result == system
      assert [{:system, %System{}}] = [result]
    end

    test "empty LLM response surfaces as {:error, :llm_returned_empty}" do
      # Per TODO 1: the compactor no longer synthesizes a
      # "[Summary of earlier conversation]" placeholder when the
      # LLM returns an empty string. The failure is surfaced
      # through the new {:error, :llm_returned_empty} contract
      # so the agent's compaction handler can set
      # :compaction_failed status and broadcast chat:error.
      messages = build_messages()

      assert {:error, :llm_returned_empty} =
               Compactor.compact(messages, 100_000, fn _ -> {:ok, ""} end)
    end
  end

  ## Helpers

  defp build_messages do
    [
      {:system, %System{index: 0, parts: [%Part.Text{text: "You are helpful"}]}},
      {:user, %User{index: 1, parts: [%Part.Text{text: "First question"}]}},
      {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "First answer"}]}},
      {:user, %User{index: 3, parts: [%Part.Text{text: "Second question"}]}},
      {:assistant, %Assistant{index: 4, parts: [%Part.Text{text: "Second answer"}]}}
    ]
  end
end
