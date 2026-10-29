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
               "Summarize the conversation in your 1500 remaining tokens."
    end

    test "appends optional guidance when provided" do
      suffix =
        CompactionProbeSupport.compaction_suffix(
          1500,
          "focus on the test plan"
        )

      assert String.ends_with?(suffix, "focus on the test plan")
    end

    test "treats empty string as no guidance" do
      assert CompactionProbeSupport.compaction_suffix(500, "") ==
               CompactionProbeSupport.compaction_suffix(500, nil)
    end
  end

  describe "compaction_mention/0" do
    test "names the tool call's arguments instead of restating them" do
      mention = CompactionProbeSupport.compaction_mention()

      # This is what a tool-triggered request carries: a pointer at the call's
      # own arguments (persisted immediately before the request), plus the
      # instruction that `preserve` is not the compactor's to write — the
      # machinery carries it into the summary message.
      assert mention =~ "`cover`"
      assert mention =~ "`preserve`"
      assert mention =~ "do not duplicate"
    end
  end

  describe "suffix_system_message/2" do
    test "wraps the suffix as a {:user, _} tuple" do
      {:user, %Nest.Messages.User{parts: [%Part.Text{text: text}]}} =
        CompactionProbeSupport.suffix_system_message(2000, nil)

      assert text =~ "2000 remaining tokens"
    end
  end

  describe "build_summarization_llm_call/3" do
    test "issues a RunRequest with the agent's prior conversation followed by the rendered suffix" do
      test_pid = self()

      cc = %ClientConfig{
        client: CaptureLLMClient,
        base_url: "https://example.test",
        api_key: "key",
        model: "test-model",
        first_byte_timeout: 30_000,
        stream_idle_timeout: 5_000
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
      # compaction request row.
      assert match?({:system, %System{}}, Enum.at(request.messages, 0))

      last = List.last(request.messages)
      assert last == suffix
    end

    test "reuses the closed-over suffix and ignores the trailing args" do
      cc = %ClientConfig{
        client: CaptureLLMClient,
        base_url: "https://example.test",
        api_key: "key",
        model: "test-model",
        first_byte_timeout: 30_000,
        stream_idle_timeout: 5_000
      }

      parent = self()

      suffix = CompactionProbeSupport.suffix_system_message(1000, "preserve code paths")
      llm_call = CompactionProbeSupport.build_summarization_llm_call(cc, parent, suffix)

      # The trailing N / guidance the compactor passes through the 3-arity
      # contract are closed over, not used: the wire payload is the rendered
      # suffix regardless.
      llm_call.(
        [{:user, %Nest.Messages.User{parts: [%Part.Text{text: "x"}]}}],
        999_999,
        "different text"
      )

      assert_receive {:captured_request, request}, 1_000

      assert List.last(request.messages) == suffix
    end
  end
end
