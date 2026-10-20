defmodule Nest.Agents.Agent.CompactionStreamedTextTest do
  @moduledoc """
  Regression tests for the raw `StreamConsumer.reduce/2` result that the
  compaction paths read.

  `Nest.Scripts.CompactionProbeSupport.consume_quietly/2` reads
  `response.text` straight off the reducer's `{:done, _}` payload instead of
  going through `Runner.consume/2`, which rebuilds the response from the
  accumulator. So on an OpenAI-style stream — text deltas in `{:text, _}`
  events, `text: nil` in the `:done` payload — the probe sees no text at all.
  These tests pin that reducer contract, and that a stream ending without
  `:done` produces no response.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer

  describe "StreamConsumer.reduce/2" do
    # The no-op hooks the quiet consume paths pass.
    defp reduce_quietly(events) do
      consumer = %StreamConsumer{
        on_text: fn _text, sent -> sent end,
        on_thinking: fn _text, sent -> sent end,
        on_signature: fn _sig -> :ok end
      }

      StreamConsumer.reduce(events, consumer)
    end

    test "OpenAI-style stream: text deltas stay in the accumulator, the done response is returned as-is" do
      events = [
        {:text, "The user requested "},
        {:text, "a summary of notes/subagents.md.\n\n"},
        {:text, "Key facts: …"},
        {:usage, %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
        {:finish_reason, "stop"},
        {:done,
         %{response: %RunResponse{text: nil, stop_reason: "stop", usage: %{input_tokens: 100}}}}
      ]

      {_acc, response, error, _sent} = reduce_quietly(events)

      assert is_nil(error)
      # The reducer does not merge `acc.text` into `response.text` (only
      # `Runner.consume/2` does), so anything reading the response directly
      # sees `nil` here.
      assert %RunResponse{text: nil, stop_reason: "stop"} = response
    end

    test "a stream that ends without :done yields no response" do
      events = [{:text, "partial"}, {:finish_reason, "stop"}]

      {_acc, response, error, _sent} = reduce_quietly(events)

      # `consume_quietly` turns this into `{:error, :no_response}`.
      assert is_nil(error)
      assert is_nil(response)
    end
  end
end
