defmodule Nest.Agents.Agent.CompactionStreamedTextTest do
  @moduledoc """
  Regression tests for the compactor's `consume_quietly/2` →
  text-merge path.

  ## What this is guarding against

  The production compactor previously returned `:llm_returned_empty`
  for every compaction whose LLM stream was structured
  OpenAI-style: streamed `:text` deltas followed by a `:done`
  event carrying a `%RunResponse{text: nil}` (the wire-level
  response only knows about `stop_reason` and `usage`; the
  caller is expected to merge text from the accumulator via
  `Runner.normalize_response/2`).

  The compactor bypasses `Runner`, so it was reading
  `response.text` directly — `nil` — and reporting the summary
  as empty. The live agent would then surface
  `chat:error ... Compaction failed: LLM returned empty summary.
  Click Retry to try again.` despite the LLM having produced
  real text.

  `Compaction.streamed_text/2` is now the merge: it prefers the
  wire-level `RunResponse.text` when populated and falls back
  to the accumulator's IO-list (`acc.text`). This test pins
  the merge so a future refactor can't reintroduce the bug.

  See `notes/context-and-compaction.md` and the agent log
  surface in `CompactionHandler.compaction_failed/3` for the
  upstream context.
  """

  use ExUnit.Case, async: true

  alias Nest.Agents.Agent.Compaction
  alias Nest.LLM.Client
  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer

  describe "streamed_text/2" do
    test "returns RunResponse.text when populated" do
      response = %RunResponse{text: "wire-level summary", stop_reason: "stop"}

      acc =
        Client.new_accumulator()
        |> Client.accumulate({:text, "should be ignored"})

      assert Compaction.streamed_text(response, acc) == "wire-level summary"
    end

    test "falls back to the accumulator when RunResponse.text is nil (OpenAI-style)" do
      response = %RunResponse{text: nil, stop_reason: "stop"}

      acc =
        Client.new_accumulator()
        |> Client.accumulate({:text, "Hello, "})
        |> Client.accumulate({:text, "world!"})

      assert Compaction.streamed_text(response, acc) == "Hello, world!"
    end

    test "falls back to the accumulator when RunResponse is nil" do
      acc =
        Client.new_accumulator()
        |> Client.accumulate({:text, "from acc"})

      assert Compaction.streamed_text(nil, acc) == "from acc"
    end

    test "returns empty string when both are empty" do
      response = %RunResponse{text: nil, stop_reason: "stop"}
      assert Compaction.streamed_text(response, Client.new_accumulator()) == ""
    end
  end

  describe "StreamConsumer.reduce + streamed_text/2 — the production merge path" do
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

    test "OpenAI-style stream with text: nil RunResponse returns the streamed text" do
      # Emulate OpenAI: many text deltas, then `{:done, _}` whose
      # RunResponse.text is nil (the wire response only carries
      # stop_reason + usage). This is the exact shape that used
      # to surface as `:llm_returned_empty`.
      events = [
        {:text, "The user requested "},
        {:text, "a summary of notes/subagents.md.\n\n"},
        {:text, "Key facts: …"},
        {:usage, %{input_tokens: 100, output_tokens: 50, total_tokens: 150}},
        {:finish_reason, "stop"},
        {:done,
         %{response: %RunResponse{text: nil, stop_reason: "stop", usage: %{input_tokens: 100}}}}
      ]

      {acc, response, error, _sent} = reduce_production_style(events)

      assert is_nil(error)
      assert Compaction.streamed_text(response, acc) =~ "The user requested"
      assert Compaction.streamed_text(response, acc) =~ "Key facts"
    end

    test "RunResponse.text wins when both are populated (Anthropic-style)" do
      # Some client paths may populate RunResponse.text directly.
      # Prefer the wire value.
      events = [
        {:text, "should be ignored"},
        {:done, %{response: %RunResponse{text: "wire summary", stop_reason: "stop"}}}
      ]

      {acc, response, error, _sent} = reduce_production_style(events)
      assert is_nil(error)
      assert Compaction.streamed_text(response, acc) == "wire summary"
    end

    test "in-band error short-circuits to {:error, _} before the merge" do
      events = [
        {:text, "partial"},
        {:error, :stream_timeout},
        {:done, %{response: %RunResponse{text: nil}}}
      ]

      {acc, response, error, _sent} = reduce_production_style(events)
      assert error == :stream_timeout

      # `consume_quietly/2`'s `cond` returns `{:error, error}`
      # before the merge; this test pins that the merge is not
      # silently producing text in the error case.
      assert compactor_consume_quietly_decision(error, response, acc) ==
               {:error, :stream_timeout}
    end

    test "stream that ends without :done returns {:error, :no_response}" do
      # `:no_response` only fires when the stream ends without a
      # `:done` event at all (e.g. the producer's parser was
      # killed mid-flight and never saw `[DONE]`). In that case
      # `response` is `nil` from the reducer's perspective.
      events = [{:text, "partial"}, {:finish_reason, "stop"}]

      {acc, response, error, _sent} = reduce_production_style(events)

      assert compactor_consume_quietly_decision(error, response, acc) ==
               {:error, :no_response}
    end
  end

  # Mirror `consume_quietly/2`'s `cond` clauses so we test the
  # decision logic in isolation rather than spinning up an
  # Agent.
  defp compactor_consume_quietly_decision(error, response, acc) do
    cond do
      not is_nil(error) -> {:error, error}
      match?(%RunResponse{}, response) -> {:ok, Compaction.streamed_text(response, acc)}
      true -> {:error, :no_response}
    end
  end
end
