defmodule Nest.Scripts.CompactionProbeSupportTest do
  @moduledoc """
  Tests for the shared helpers used by the compaction recovery
  and probe scripts. Keeps the two scripts in lockstep: if the
  probe says the LLM works, the recovery script sees the same
  prompt shape and provider resolution.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.ClientConfig
  alias Nest.LLM.RunRequest
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Scripts.CompactionProbeSupport
  alias Nest.Support.CaptureLLMClient

  describe "compaction_suffix/2" do
    test "formats the suffix with the budget hint" do
      suffix = CompactionProbeSupport.compaction_suffix(1500, nil)

      assert suffix ==
               "[mode: compact] Summarize the conversation in your 1500 remaining tokens."
    end

    test "appends optional guidance when provided" do
      suffix =
        CompactionProbeSupport.compaction_suffix(
          1500,
          "focus on the test plan"
        )

      assert String.starts_with?(
               suffix,
               "[mode: compact] Summarize the conversation in your 1500 remaining tokens."
             )

      assert String.ends_with?(suffix, "focus on the test plan")
    end

    test "treats empty string as no guidance" do
      assert CompactionProbeSupport.compaction_suffix(500, "") ==
               CompactionProbeSupport.compaction_suffix(500, nil)
    end

    test "is stable across calls for the same args" do
      assert CompactionProbeSupport.compaction_suffix(1000, "x") ==
               CompactionProbeSupport.compaction_suffix(1000, "x")
    end
  end

  describe "suffix_system_message/2" do
    test "wraps the suffix as a {:system, _} tuple" do
      msg = CompactionProbeSupport.suffix_system_message(2000, nil)

      assert match?({:system, %System{}}, msg)
      {:system, %System{parts: [%Part.Text{text: text}]}} = msg
      assert text =~ "[mode: compact]"
      assert text =~ "2000 remaining tokens"
    end

    test "the system message has empty api_logs (empty list)" do
      {:system, %System{api_logs: api_logs}} =
        CompactionProbeSupport.suffix_system_message(2000, nil)

      assert api_logs == []
    end
  end

  describe "build_summarization_llm_call/3" do
    test "captures the ClientConfig and returns a 3-arity function" do
      cc = %ClientConfig{
        client: CaptureLLMClient,
        base_url: "https://example.test",
        api_key: "key",
        model: "test-model",
        receive_timeout: 30_000
      }

      parent = self()

      suffix =
        CompactionProbeSupport.suffix_system_message(1500, nil)

      llm_call = CompactionProbeSupport.build_summarization_llm_call(cc, parent, suffix)

      assert is_function(llm_call, 3)
    end

    test "issues a RunRequest with the agent's prior conversation followed by the rendered suffix" do
      test_pid = self()

      cc = %ClientConfig{
        client: CaptureLLMClient,
        base_url: "https://example.test",
        api_key: "key",
        model: "test-model",
        receive_timeout: 30_000
      }

      suffix =
        CompactionProbeSupport.suffix_system_message(1500, "focus on file paths")

      llm_call = CompactionProbeSupport.build_summarization_llm_call(cc, test_pid, suffix)

      input = [
        {:system, %System{parts: [%Part.Text{text: "vocation prompt"}]}},
        {:user, %Nest.Messages.User{parts: [%Part.Text{text: "summarize me"}]}}
      ]

      llm_call.(input, 1500, "focus on file paths")

      assert_receive {:captured_request, %RunRequest{} = request}, 1_000
      assert request.model == "test-model"
      assert request.tool_choice == :none
      assert request.tools == nil
      assert request.stream == true

      # The agent's own system prompt is at position 0 (NOT
      # stripped — KV cache prefix lines up with the agent's
      # last LLM call). The trailing message is the rendered
      # [mode: compact] suffix.
      assert match?({:system, %System{}}, Enum.at(request.messages, 0))

      last = List.last(request.messages)
      assert last == suffix
    end

    test "the closed-over rendered suffix is reused verbatim on each call" do
      cc = %ClientConfig{
        client: CaptureLLMClient,
        base_url: "https://example.test",
        api_key: "key",
        model: "test-model",
        receive_timeout: 30_000
      }

      parent = self()

      suffix = CompactionProbeSupport.suffix_system_message(1000, "preserve code paths")
      llm_call = CompactionProbeSupport.build_summarization_llm_call(cc, parent, suffix)

      # Same suffix regardless of which N / guidance the
      # compactor passes through the trailing args (those are
      # closed over, not used).
      llm_call.(
        [{:user, %Nest.Messages.User{parts: [%Part.Text{text: "x"}]}}],
        1000,
        "preserve code paths"
      )

      assert_receive {:captured_request, req_a}, 1_000

      llm_call.(
        [{:user, %Nest.Messages.User{parts: [%Part.Text{text: "x"}]}}],
        999_999,
        "different text"
      )

      assert_receive {:captured_request, req_b}, 1_000

      assert List.last(req_a.messages) == suffix
      assert List.last(req_b.messages) == suffix
    end
  end
end
