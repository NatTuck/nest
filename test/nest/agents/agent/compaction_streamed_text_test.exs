defmodule Nest.Agents.Agent.CompactionStreamedTextTest do
  @moduledoc """
  Regression tests for the compactor's `consume_quietly/2` →
  `RunResponse` extraction path.

  ## What this is guarding against

  The compactor's LLM call now returns the full `RunResponse`
  (not just the text), so the caller can record the assistant
  message as-received — preserving `usage`, `stop_reason`,
  `model`, and any `` markers in the visible text.
  The compactor extracts `.text` for the empty-summary guard
  and forwards both to the caller.

  `consume_quietly/2`'s decision logic (error short-circuit;
  `:no_response` when the stream ends without `:done`) is the
  one thing that could regress, so this file pins it.

  See `notes/context-and-compaction.md` for the upstream
  context.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer

  describe "StreamConsumer.reduce + consume_quietly/2 decision" do
    # Replicates the in-line state machine `consume_quietly/2`
    # uses, minus the broadcast-forwarding side effects.
    defp reduce_production_style(events) do
      consumer = %StreamConsumer{
        on_text: fn _text, sent -> sent end,
        on_thinking: fn _text, sent -> sent end,
        on_signature: fn _sig -> :ok end
      }

      StreamConsumer.reduce(events, consumer)
    end

    test "OpenAI-style stream with text: nil RunResponse returns the response (text via .text accessor)" do
      events = [
        {:text, "The user requested "},
        {:text, "a summary of notes/subagents.md.\n\n"},
        {:text, "Key facts: …"},
        {:usage, %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
        {:finish_reason, "stop"},
        {:done,
         %{response: %RunResponse{text: nil, stop_reason: "stop", usage: %{input_tokens: 100}}}}
      ]

      {_acc, response, error, _sent} = reduce_production_style(events)

      assert is_nil(error)
      assert %RunResponse{} = response
      # The stream-consumer doesn't merge acc.text into response.text
      # (that's the caller's job via the compactor's downstream
      # extraction). This test just pins that the response is
      # returned intact, with text: nil for OpenAI-style streams.
      assert response.text == nil
      assert response.stop_reason == "stop"
    end

    test "RunResponse.text wins when populated (Anthropic-style)" do
      events = [
        {:text, "ignored"},
        {:done, %{response: %RunResponse{text: "wire summary", stop_reason: "stop"}}}
      ]

      {_acc, response, error, _sent} = reduce_production_style(events)
      assert is_nil(error)
      assert response.text == "wire summary"
    end

    test "in-band error short-circuits to {:error, _} before the response is returned" do
      events = [
        {:text, "partial"},
        {:error, :stream_timeout},
        {:done, %{response: %RunResponse{text: nil}}}
      ]

      {_acc, _response, error, _sent} = reduce_production_style(events)
      assert error == :stream_timeout

      # `consume_quietly/2`'s `cond` returns `{:error, error}`
      # before the response is unwrapped; this test pins that
      # the decision is not silently producing a response in
      # the error case.
      assert compactor_consume_quietly_decision(error) == {:error, :stream_timeout}
    end

    test "stream that ends without :done returns {:error, :no_response}" do
      events = [{:text, "partial"}, {:finish_reason, "stop"}]

      {_acc, response, error, _sent} = reduce_production_style(events)

      assert compactor_consume_quietly_decision(error, response) ==
               {:error, :no_response}
    end
  end

  # Mirror `consume_quietly/2`'s `cond` clauses so we test the
  # decision logic in isolation rather than spinning up an
  # Agent. Under the new design, on success we return the full
  # RunResponse (the caller extracts `.text`); the merge
  # happens downstream.
  defp compactor_consume_quietly_decision(error, response \\ nil) do
    cond do
      not is_nil(error) -> {:error, error}
      match?(%RunResponse{}, response) -> {:ok, response}
      true -> {:error, :no_response}
    end
  end
end
