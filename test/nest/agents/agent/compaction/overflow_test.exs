defmodule Nest.Agents.Agent.Compaction.OverflowTest do
  @moduledoc """
  Tests for `Nest.Agents.Agent.Compaction.Overflow`.

  Verifies the unified message format shared by
  `chat_pipeline.ex:refuse_compaction/1` (`:cannot_compact`)
  and `trigger.ex:broadcast_reserve_exhausted/1`
  (`:reserve_exhausted`). The two paths used to have
  near-duplicate copies of the message; this test pins the
  unified format so they can't drift again.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Compaction.Overflow
  alias Nest.Agents.Agent.LlmMetrics
  alias Nest.Messages.Part
  alias Nest.Messages.System

  defp build_state(context_limit, sys_text) do
    %Nest.Agents.Agent{
      name: "test-agent",
      llm_metrics: %LlmMetrics{context_limit: context_limit},
      chat_state: %Nest.Agents.Agent.ChatState{
        messages: [
          {:system,
           %System{
             index: 0,
             parts: [%Part.Text{text: sys_text}],
             api_logs: []
           }}
        ]
      }
    }
  end

  describe "message/2" do
    test "includes limit, system prompt size, and reserve size in tokens" do
      state = build_state(10_000, String.duplicate("z", 7_000))
      msg = Overflow.message(state, "start a conversation")

      assert msg =~ "Cannot start a conversation:"
      assert msg =~ "context limit (10000)"
      assert msg =~ "system prompt"
      assert msg =~ "reserved response budget (8192 tokens)"
      assert msg =~ "Use a model with a larger context window"
    end

    test "verb 'compact' produces the compact-pipeline message" do
      state = build_state(10_000, String.duplicate("z", 7_000))
      msg = Overflow.message(state, "compact")

      assert msg =~ "Cannot compact:"
      assert msg =~ "context limit (10000)"
      assert msg =~ "reserved response budget (8192 tokens)"
    end

    test "default verb is 'compact' (matches the trigger's :reserve_exhausted case)" do
      state = build_state(10_000, String.duplicate("z", 7_000))
      msg = Overflow.message(state)

      assert msg =~ "Cannot compact:"
    end

    test "falls back to the full message-list size when no system message is present" do
      state = %Nest.Agents.Agent{
        name: "test-agent",
        llm_metrics: %LlmMetrics{context_limit: 10_000},
        chat_state: %Nest.Agents.Agent.ChatState{
          messages: [
            {:user,
             %Nest.Messages.User{
               index: 0,
               parts: [%Part.Text{text: "hello"}],
               api_logs: []
             }}
          ]
        }
      }

      # Should not raise; falls back to estimating the full list.
      msg = Overflow.message(state, "compact")
      assert is_binary(msg)
      assert msg =~ "context limit (10000)"
    end
  end

  describe "system_size/1" do
    test "returns the system message's token count" do
      state = build_state(10_000, String.duplicate("a", 100))
      assert Overflow.system_size(state) > 0
    end

    test "falls back to the full message-list size when no system message" do
      state = %Nest.Agents.Agent{
        name: "test-agent",
        llm_metrics: %LlmMetrics{context_limit: 10_000},
        chat_state: %Nest.Agents.Agent.ChatState{
          messages: [
            {:user,
             %Nest.Messages.User{
               index: 0,
               parts: [%Part.Text{text: "hi"}],
               api_logs: []
             }}
          ]
        }
      }

      assert Overflow.system_size(state) > 0
    end
  end
end
