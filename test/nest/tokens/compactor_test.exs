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

  # The rendered system prompt text. `compute_summary_budget/4`
  # takes the rendered string directly (it does not look at
  # `state.chat_state.messages[0]` — that path can drift and
  # the size must not depend on it).
  defp system_text, do: "You are helpful"

  # A small `{:system, %System{}}` message. Use this for
  # `compact/3` tests; for `compute_summary_budget/4` use
  # `system_text/0` instead.
  defp build_system do
    {:system, %System{index: 0, parts: [%Part.Text{text: system_text()}]}}
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
    test "returns the LLM's text, sending the full prior conversation in one pass (nil guidance)" do
      test_pid = self()

      assert {:ok, "head", %RunResponse{}} =
               Compactor.compact(
                 build_messages(),
                 32_768,
                 capture_llm_call(test_pid, "head")
               )

      # Pass 1 input is the agent's full prior conversation, in order
      # (KV cache reuse), and `compact/3` has no guidance to pass.
      assert_received {:llm_called, input, _remaining_tokens, nil}
      assert length(input) == 5
      assert match?({:system, %System{}}, Enum.at(input, 0))
      assert match?({:user, %User{}}, Enum.at(input, 1))
      assert match?({:assistant, %Assistant{}}, Enum.at(input, 2))
      assert match?({:user, %User{}}, Enum.at(input, 3))
      assert match?({:assistant, %Assistant{}}, Enum.at(input, 4))
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
      assert {:ok, n, rendered_suffix} =
               Compactor.compute_summary_budget(100_000, system_text(), [build_system()], nil)

      assert n > 0

      # Rendered suffix carries the chosen N.
      {:user, %User{parts: [%Part.Text{text: rendered}]}} = rendered_suffix
      assert rendered =~ "in your #{n} remaining tokens"
    end

    test "system size is measured, not a constant" do
      small_system = "sys"

      big_system = String.duplicate("big system prompt. ", 200)

      msgs = [build_system(), {:user, %User{index: 1, parts: [%Part.Text{text: "Q"}]}}]

      {:ok, n_small, _} = Compactor.compute_summary_budget(100_000, small_system, msgs, nil)
      {:ok, n_big, _} = Compactor.compute_summary_budget(100_000, big_system, msgs, nil)

      # Bigger system → smaller N. The difference is roughly the
      # estimator delta for the system content plus per-message overhead.
      assert n_small > n_big
    end

    test "compaction_request_size scales with optional_guidance length" do
      system = system_text()

      {:ok, _, suffix_nil} =
        Compactor.compute_summary_budget(100_000, system, [build_system()], nil)

      {:ok, _, suffix_short} =
        Compactor.compute_summary_budget(100_000, system, [build_system()], "preserve code paths")

      {:ok, _, suffix_long} =
        Compactor.compute_summary_budget(
          100_000,
          system,
          [build_system()],
          String.duplicate("extra guidance. ", 50)
        )

      {:user, %User{parts: [%Part.Text{text: nil_text}]}} = suffix_nil
      {:user, %User{parts: [%Part.Text{text: short_text}]}} = suffix_short
      {:user, %User{parts: [%Part.Text{text: long_text}]}} = suffix_long

      assert String.length(long_text) > String.length(short_text)
      assert String.length(short_text) > String.length(nil_text)
    end

    test "a system that fills most of the reserve still yields a usable budget" do
      # 32k context → reserve = 8_192. With a ~5.4k-token system the
      # headroom left for the summary is small but real — the refusal
      # case is the next test.
      huge_system = String.duplicate("system. ", 1_500)

      {:ok, n, _} = Compactor.compute_summary_budget(32_768, huge_system, [build_system()], nil)

      assert n >= 1
    end

    test "returns {:error, :reserve_exhausted} when reserve can't fit system + suffix" do
      # 32k context, 8k reserve, with a system that alone overruns the
      # reserve. There's no room for the suffix + any summary text.
      huge_system = String.duplicate("system content. ", 2_500)

      assert Compactor.compute_summary_budget(32_768, huge_system, [build_system()], nil) ==
               {:error, :reserve_exhausted}
    end
  end
end
