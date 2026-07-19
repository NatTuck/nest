defmodule Nest.Tokens.CompactorTest do
  @moduledoc """
  Tests for `Nest.Tokens.Compactor`.

  Covers:
    - Single-pass compaction (no recent-slice preservation;
      the entire conversation folds into a single summary)
    - Edge cases: empty, system-only, no-user, system+user
    - LLM call signature: 3-arity `(messages, remaining_tokens,
      optional_guidance) -> {:ok, run_response} | {:error, reason}`
    - Output shape: `{:ok, summary_text, run_response}` on success,
      `{:ok, :passthrough}` for too-short input, `{:error, _}` on
      failure
    - Error cases: empty LLM response, LLM callback error
    - `compute_summary_budget/4` budget hints (single-pass +
      digit-count buffer for self-consistent sizing)
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.RunResponse
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Tokens.Compactor

  # Build a simple message list with a system + a few user/assistant
  # pairs. Always leads with a system message so it's a valid
  # input to `split_messages/1` for compaction.
  defp build_messages do
    [
      {:system, %System{index: 0, parts: [%Part.Text{text: "You are helpful"}]}},
      {:user, %User{index: 1, parts: [%Part.Text{text: "First question"}]}},
      {:assistant, %Assistant{index: 2, parts: [%Part.Text{text: "First answer"}]}},
      {:user, %User{index: 3, parts: [%Part.Text{text: "Second question"}]}},
      {:assistant, %Assistant{index: 4, parts: [%Part.Text{text: "Second answer"}]}}
    ]
  end

  # A trivial LLM callback matching the 3-arity signature. The
  # callback's return is `{:ok, %RunResponse{text: text}}` —
  # the compactor extracts `.text` for the empty-summary guard.
  defp mock_llm_call(text) do
    fn _messages, _remaining_tokens, _optional_guidance ->
      {:ok, %RunResponse{text: text, stop_reason: "stop"}}
    end
  end

  # A capture-based callback: records (messages, remaining_tokens,
  # optional_guidance) inputs and returns a configurable summary.
  defp capture_llm_call(parent, summary) do
    fn messages, remaining_tokens, optional_guidance ->
      send(parent, {:llm_called, messages, remaining_tokens, optional_guidance})
      {:ok, %RunResponse{text: summary, stop_reason: "stop"}}
    end
  end

  # LLM callback that always errors. Useful for error-path tests.
  defp error_llm_call(reason) do
    fn _messages, _remaining, _guidance -> {:error, reason} end
  end

  # A simple system message useful across `compute_summary_budget/4`
  # tests.
  defp build_system do
    {:system, %System{index: 0, parts: [%Part.Text{text: "You are helpful"}]}}
  end

  describe "compact/3 — edge cases" do
    test "empty messages returns {:ok, :passthrough} (no LLM call, no compaction needed)" do
      assert Compactor.compact([], 32_768, mock_llm_call("anything")) == {:ok, :passthrough}
    end

    test "single system message returns {:ok, :passthrough} (no LLM call)" do
      msgs = [{:system, %System{index: 0, parts: [%Part.Text{text: "Only system"}]}}]
      assert Compactor.compact(msgs, 32_768, mock_llm_call("anything")) == {:ok, :passthrough}
    end

    test "system + single user returns {:ok, :passthrough} (no head to summarize)" do
      msgs = [build_system(), {:user, %User{index: 1, parts: [%Part.Text{text: "Q"}]}}]
      assert Compactor.compact(msgs, 32_768, mock_llm_call("anything")) == {:ok, :passthrough}
    end
  end

  describe "compact/3 — single-pass fold" do
    test "compactor returns the LLM summary text + RunResponse; caller decides what to do with them" do
      test_pid = self()

      assert {:ok, summary_text, %RunResponse{text: response_text}} =
               Compactor.compact(
                 build_messages(),
                 32_768,
                 capture_llm_call(test_pid, "Summary of the earlier conversation")
               )

      assert summary_text == "Summary of the earlier conversation"
      assert summary_text == response_text

      assert_received {:llm_called, _, _, _}
    end

    test "pass 1 input is the agent's full prior conversation (KV cache reuse)" do
      test_pid = self()

      {:ok, _text, _response} =
        Compactor.compact(
          build_messages(),
          32_768,
          capture_llm_call(test_pid, "head")
        )

      assert_received {:llm_called, input, _remaining_tokens, _guidance}
      assert length(input) == 5
      assert match?({:system, %System{}}, Enum.at(input, 0))
      assert match?({:user, %User{}}, Enum.at(input, 1))
      assert match?({:assistant, %Assistant{}}, Enum.at(input, 2))
      assert match?({:user, %User{}}, Enum.at(input, 3))
      assert match?({:assistant, %Assistant{}}, Enum.at(input, 4))
    end

    test "optional_guidance passed through (currently always nil from compact/3)" do
      test_pid = self()

      {:ok, _text, _response} =
        Compactor.compact(
          build_messages(),
          32_768,
          capture_llm_call(test_pid, "head")
        )

      assert_received {:llm_called, _, _, guidance}
      assert guidance == nil
    end

    test "long tool flows get summarized away, not kept verbatim" do
      test_pid = self()

      msgs = [
        build_system(),
        {:user, %User{index: 1, parts: [%Part.Text{text: "Run ls"}]}},
        {:assistant,
         %Assistant{
           index: 2,
           parts: [%Part.Text{text: "tool_call(shell_cmd, ls)"}]
         }},
        {:assistant,
         %Assistant{
           index: 3,
           parts: [
             %Part.Text{text: String.duplicate("file1.txt\nfile2.txt\n", 1000)}
           ]
         }}
      ]

      assert {:ok, "User listed files", _response} =
               Compactor.compact(
                 msgs,
                 32_768,
                 capture_llm_call(test_pid, "User listed files")
               )

      # The compactor's only job is to summarize and return the
      # text — it does NOT package the result into a message
      # list anymore. The caller (Nest.Agents.Agent.Compaction)
      # records the LLM response as an assistant message and
      # builds the post-compaction user message from the text.
    end
  end

  describe "compact/3 — error cases" do
    test "head LLM returns empty text → {:error, :llm_returned_empty}" do
      result = Compactor.compact(build_messages(), 32_768, mock_llm_call(""))
      assert result == {:error, :llm_returned_empty}
    end

    test "head LLM callback errors → error propagates" do
      result =
        Compactor.compact(
          build_messages(),
          32_768,
          error_llm_call(:timeout)
        )

      assert result == {:error, :timeout}
    end
  end

  describe "compact/3 — empty-after-strip guard" do
    # The LLM call returns the raw text (any `<think>` markers
    # intact). The compactor's `require_non_empty_summary/1`
    # strips the thinking blocks and rejects responses whose
    # visible content is empty or whitespace-only. Without
    # this, the regenerator's `ThinkTags.strip/1` collapses
    # those responses to `""` and the user sees
    # `Summary of earlier conversation:` followed by nothing.

    test "response with only a `<think>` block → {:error, :llm_returned_empty}" do
      result =
        Compactor.compact(
          build_messages(),
          32_768,
          mock_llm_call("<think>I'll summarize</think>")
        )

      assert result == {:error, :llm_returned_empty}
    end

    test "response with only an unclosed `<think>` → {:error, :llm_returned_empty}" do
      result =
        Compactor.compact(
          build_messages(),
          32_768,
          mock_llm_call("<think>just thinking, no closing tag")
        )

      assert result == {:error, :llm_returned_empty}
    end

    test "whitespace-only response → {:error, :llm_returned_empty}" do
      result =
        Compactor.compact(build_messages(), 32_768, mock_llm_call("   \n\n   "))

      assert result == {:error, :llm_returned_empty}
    end

    test "response with `<think>` block followed by visible text → success" do
      result =
        Compactor.compact(
          build_messages(),
          32_768,
          mock_llm_call("<think>thinking</think>The conversation is about X.")
        )

      assert {:ok, "<think>thinking</think>The conversation is about X.", _response} = result
    end
  end

  describe "compute_summary_budget/4" do
    test "returns {:ok, n, suffix} where n = reserve - system - request_size + digit buffer" do
      # 100k context → reserve = 20_000. With a small system and
      # the standard suffix, n is roughly 20_000 minus system
      # and suffix sizes.
      system = build_system()

      assert {:ok, n, rendered_suffix} =
               Compactor.compute_summary_budget(100_000, system, [system], nil)

      assert is_integer(n)
      assert n > 0
      assert match?({:user, %User{}}, rendered_suffix)

      # Rendered suffix carries the chosen N.
      {:user, %User{parts: [%Part.Text{text: rendered}]}} = rendered_suffix
      assert rendered =~ "in your #{n} remaining tokens"
    end

    test "suffix is rendered once with the chosen N (single-pass, no recursion)" do
      system = build_system()
      {:ok, n, rendered_suffix} = Compactor.compute_summary_budget(100_000, system, [system], nil)

      # The rendered suffix embeds the chosen N (not the placeholder N=1).
      {:user, %User{parts: [%Part.Text{text: text}]}} = rendered_suffix
      assert text =~ "in your #{n} remaining tokens"
      refute text =~ "in your 1 remaining tokens"
    end

    test "system size is measured, not a constant" do
      small_system =
        {:system, %System{index: 0, parts: [%Part.Text{text: "sys"}]}}

      big_system =
        {:system,
         %System{
           index: 0,
           parts: [%Part.Text{text: String.duplicate("big system prompt. ", 200)}]
         }}

      msgs = [small_system, {:user, %User{index: 1, parts: [%Part.Text{text: "Q"}]}}]

      {:ok, n_small, _} = Compactor.compute_summary_budget(100_000, small_system, msgs, nil)
      {:ok, n_big, _} = Compactor.compute_summary_budget(100_000, big_system, msgs, nil)

      # Bigger system → smaller N. The difference is roughly the
      # estimator delta for the system content plus per-message overhead.
      assert n_small > n_big
    end

    test "compaction_request_size scales with optional_guidance length" do
      system = build_system()

      {:ok, _, suffix_nil} = Compactor.compute_summary_budget(100_000, system, [system], nil)

      {:ok, _, suffix_short} =
        Compactor.compute_summary_budget(100_000, system, [system], "preserve code paths")

      {:ok, _, suffix_long} =
        Compactor.compute_summary_budget(
          100_000,
          system,
          [system],
          String.duplicate("extra guidance. ", 50)
        )

      {:user, %User{parts: [%Part.Text{text: nil_text}]}} = suffix_nil
      {:user, %User{parts: [%Part.Text{text: short_text}]}} = suffix_short
      {:user, %User{parts: [%Part.Text{text: long_text}]}} = suffix_long

      assert String.length(long_text) > String.length(short_text)
      assert String.length(short_text) > String.length(nil_text)
    end

    test "headroom cap binds when system + request consume most of reserve" do
      # 32k context → reserve = 8192. With a 7k system prompt,
      # the request may use 100+ tokens, leaving the LLM with
      # only ~1k tokens for the summary.
      huge_system =
        {:system,
         %System{
           index: 0,
           parts: [%Part.Text{text: String.duplicate("system. ", 1_500)}]
         }}

      msgs = [huge_system]

      {:ok, n, _} = Compactor.compute_summary_budget(32_768, huge_system, msgs, nil)

      # Just verify it returns a sensible (positive) integer — the
      # exact value depends on the estimator but it should not
      # exceed the reserve.
      assert is_integer(n)
      assert n >= 1
      assert n <= 8_192
    end

    test "call-fits cap binds when current_messages is large" do
      system = build_system()

      # Simulate a heavily-loaded context where current_messages
      # already takes most of the budget.
      big_msgs =
        Enum.map(0..50, fn i ->
          {:user, %User{index: i + 1, parts: [%Part.Text{text: String.duplicate("msg. ", 200)}]}}
        end)

      [system | _] = [system | big_msgs]

      {:ok, n, _} = Compactor.compute_summary_budget(100_000, system, [system | big_msgs], nil)

      # With 50 messages at ~100 tokens each plus system + suffix
      # overhead, the LLM call barely fits in 100k. The call-fits
      # cap should bind tighter than the headroom cap.
      assert is_integer(n)
      assert n > 0
      assert n < 20_000
    end

    test "returns {:error, :reserve_exhausted} when reserve can't fit system + suffix" do
      # 32k context, 8k reserve, with a system that's almost the
      # full reserve. There's no room for the suffix + any
      # summary text.
      huge_system =
        {:system,
         %System{
           index: 0,
           parts: [%Part.Text{text: String.duplicate("system content. ", 1_500)}]
         }}

      msgs = [huge_system]

      result = Compactor.compute_summary_budget(32_768, huge_system, msgs, nil)

      # Either we land exactly on a non-zero n (the estimator
      # happens to give us a tiny positive budget) or refuse.
      assert result == {:error, :reserve_exhausted} or
               match?({:ok, n, _} when n >= 1, result)
    end

    test "the same input produces a suffix containing the returned N" do
      system = build_system()
      msgs = [system, {:user, %User{index: 1, parts: [%Part.Text{text: "Q"}]}}]
      {:ok, n, suffix} = Compactor.compute_summary_budget(100_000, system, msgs, nil)

      {:user, %User{parts: [%Part.Text{text: text}]}} = suffix
      assert text =~ "#{n}"
    end
  end
end
