defmodule Nest.Tokens.CompactorTest do
  @moduledoc """
  Tests for `Nest.Tokens.Compactor`.

  Covers:
  - Single-pass compaction (recent slice fits in 25%)
  - Two-pass compaction (recent slice too big, head + tail summaries)
  - Edge cases: empty, system-only, no head to summarize
  - LLM call ordering and content passed to it
  - Output message structure (system + head summary + last user + tail/responses)
  """

  use ExUnit.Case, async: true

  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.Compactor

  # Build a simple message list with a system + a few user/assistant
  # pairs.
  defp build_messages do
    [
      {:system, %System{index: 0, content: "You are helpful"}},
      {:user, %User{index: 1, content: "First question"}},
      {:assistant, %Assistant{index: 2, content: "First answer"}},
      {:user, %User{index: 3, content: "Second question"}},
      {:assistant, %Assistant{index: 4, content: "Second answer"}}
    ]
  end

  # A trivial LLM callback that returns a fixed summary. Tests can
  # use the capture variant to inspect what the compactor passed.
  defp mock_llm_call(text) do
    fn _messages -> text end
  end

  # A capture-based callback: records the messages it received
  # and returns a configurable summary.
  defp capture_llm_call(parent, summary) do
    fn messages ->
      send(parent, {:llm_called, messages})
      summary
    end
  end

  describe "compact/3 — edge cases" do
    test "empty messages returns empty" do
      result = Compactor.compact([], 32_768, mock_llm_call("anything"))
      assert result == []
    end

    test "single system message returns as-is (no compaction needed)" do
      msgs = [{:system, %System{index: 0, content: "Only system"}}]
      assert Compactor.compact(msgs, 32_768, mock_llm_call("anything")) == msgs
    end

    test "no user message returns as-is" do
      msgs = [
        {:system, %System{index: 0, content: "System"}},
        {:assistant, %Assistant{index: 1, content: "Assistant reply"}}
      ]

      assert Compactor.compact(msgs, 32_768, mock_llm_call("anything")) == msgs
    end
  end

  describe "compact/3 — single-pass (recent slice fits in 25%)" do
    test "summarizes the head, keeps recent slice verbatim" do
      test_pid = self()

      new_messages =
        Compactor.compact(
          build_messages(),
          32_768,
          capture_llm_call(test_pid, "Summary of the earlier conversation")
        )

      # Should have received exactly one LLM call (pass 1)
      assert_received {:llm_called, _input}

      # Output should be: system, head summary, last user, responses
      assert length(new_messages) == 4
      assert match?({:system, %System{}}, hd(new_messages))
      assert match?({:system, %System{}}, Enum.at(new_messages, 1))
      assert match?({:user, %User{}}, Enum.at(new_messages, 2))
      assert match?({:assistant, %Assistant{}}, Enum.at(new_messages, 3))

      # The head summary should contain the LLM's output
      {:system, %System{content: head_content}} = Enum.at(new_messages, 1)
      assert head_content =~ "Summary of the earlier conversation"

      # The last user and assistant should be unchanged
      {:user, %User{content: last_user_content}} = Enum.at(new_messages, 2)
      assert last_user_content == "Second question"

      {:assistant, %Assistant{content: last_asst_content}} = Enum.at(new_messages, 3)
      assert last_asst_content == "Second answer"
    end

    test "pass 1 input includes system + head (NOT responses)" do
      test_pid = self()

      Compactor.compact(
        build_messages(),
        32_768,
        capture_llm_call(test_pid, "head")
      )

      assert_received {:llm_called, input}
      # Input should be: system, [first user, first assistant]
      # (everything before the last user, with system prepended)
      assert length(input) == 3
      assert match?({:system, %System{}}, Enum.at(input, 0))
      assert match?({:user, %User{}}, Enum.at(input, 1))
      assert match?({:assistant, %Assistant{}}, Enum.at(input, 2))
    end
  end

  describe "compact/3 — two-pass (recent slice too big)" do
    test "tight context budget forces a second pass" do
      test_pid = self()

      # 8k context with a 25% threshold = 2k. We use a 60k
      # "summary" of mixed text (not single-char repeats, which
      # BPE compresses ~8x) so the estimate actually reflects
      # the intent.
      big_head = String.duplicate("hello world ", 5_000)

      new_messages =
        Compactor.compact(
          build_messages(),
          8_192,
          capture_llm_call(test_pid, big_head)
        )

      # Two calls: first returns the big head, second returns tail
      assert_received {:llm_called, _input1}
      assert_received {:llm_called, _input2}

      # Output should be: system, head summary, last user, tail summary
      assert length(new_messages) == 4
      assert match?({:system, %System{}}, Enum.at(new_messages, 0))
      assert match?({:system, %System{}}, Enum.at(new_messages, 1))
      assert match?({:user, %User{}}, Enum.at(new_messages, 2))
      assert match?({:system, %System{}}, Enum.at(new_messages, 3))

      # The third (tail summary) should contain the tail LLM call
      # output. Since both calls return big_head, the tail summary
      # also has the big content (wrapped with a prefix). Use
      # a prefix check to avoid trailing-whitespace gotchas from
      # String.trim inside wrap_summary.
      {:system, %System{content: tail_content}} = Enum.at(new_messages, 3)
      assert String.contains?(tail_content, String.slice(big_head, 0, 100))
    end

    test "pass 2 input includes system + head_summary + last_user + responses" do
      test_pid = self()

      big_head = String.duplicate("hello world ", 5_000)

      Compactor.compact(
        build_messages(),
        8_192,
        capture_llm_call(test_pid, big_head)
      )

      assert_received {:llm_called, _input1}
      assert_received {:llm_called, input2}

      # Pass 2 input: system, [head summary, last user, last assistant]
      assert length(input2) == 4
      assert match?({:system, %System{}}, Enum.at(input2, 0))
      # The 2nd element is the head summary (a system message)
      assert match?({:system, %System{}}, Enum.at(input2, 1))
      # Then last user + last assistant
      assert match?({:user, %User{}}, Enum.at(input2, 2))
      assert match?({:assistant, %Assistant{}}, Enum.at(input2, 3))
    end
  end

  describe "compact/3 — minimum input" do
    test "system + single user: head is empty, pass 1 still runs" do
      test_pid = self()

      msgs = [
        {:system, %System{index: 0, content: "Sys"}},
        {:user, %User{index: 1, content: "Q"}}
      ]

      new_messages =
        Compactor.compact(
          msgs,
          32_768,
          capture_llm_call(test_pid, "")
        )

      # Pass 1 ran (with empty head)
      assert_received {:llm_called, input}
      # Input was [system] (head was empty, just system prepended)
      assert length(input) == 1
      assert match?({:system, %System{}}, hd(input))

      # Output: system, [head summary placeholder], user
      assert length(new_messages) == 3
      assert match?({:system, %System{}}, Enum.at(new_messages, 0))
      assert match?({:system, %System{}}, Enum.at(new_messages, 1))
      assert match?({:user, %User{}}, Enum.at(new_messages, 2))
    end
  end

  describe "compact/3 — 25% threshold precision" do
    test "just at the threshold: single pass" do
      test_pid = self()
      # 8k context * 25% = 2k. A 200-repeat summary is
      # ~500 tokens with safety — well under 2k → single pass.
      head = String.duplicate("hello world ", 200)

      new_messages =
        Compactor.compact(
          build_messages(),
          8_192,
          capture_llm_call(test_pid, head)
        )

      # Single pass
      assert_received {:llm_called, _}
      refute_received {:llm_called, _}

      assert length(new_messages) == 4
    end

    test "just over the threshold: two passes" do
      test_pid = self()
      # Same context, but a 10k-repeat summary — ~12k tokens
      # with safety, way over the 2k threshold → two passes.
      head = String.duplicate("hello world ", 10_000)

      new_messages =
        Compactor.compact(
          build_messages(),
          8_192,
          capture_llm_call(test_pid, head)
        )

      # Two passes
      assert_received {:llm_called, _}
      assert_received {:llm_called, _}

      # Four messages: system, head summary, user, tail summary
      assert length(new_messages) == 4
    end
  end
end
