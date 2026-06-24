defmodule Nest.LLM.OpenAIClientUsageTest do
  @moduledoc """
  Tests for the OpenAI usage parsing path (`parse_usage/1`),
  reached via `events_from_metadata/1` when a usage-only frame
  arrives (the typical `stream_options.include_usage: true`
  shape).

  Lives in its own file to keep `openai_client_test.exs` under
  the 500-line credo cap.

  Verifies:

    * `cached_tokens` is split off from `prompt_tokens` so
      `input_tokens` carries the new (non-cached) portion (the
      same wire-format semantics as the Anthropic client).
    * `reasoning_tokens` from `completion_tokens_details` is
      captured alongside `output_tokens` (the cost module
      reads `output_tokens`, which already includes reasoning).
    * Missing `*_details` sub-objects default to 0.
    * A malformed payload with `cached_tokens > prompt_tokens`
      is defensively clamped to 0 instead of producing a
      negative `input_tokens`.
  """

  use ExUnit.Case, async: true

  alias Nest.LLM.OpenAIClient

  defp run_with_chunk(chunk) do
    parent = self()

    spawn_link(fn ->
      send(parent, {:req_chunk, chunk})
      send(parent, :req_done)
    end)

    stream = OpenAIClient.consume_sse_from_mailbox()
    Enum.to_list(stream)
  end

  describe "parse_usage (via :usage event from events_from_metadata)" do
    test "splits prompt_tokens into new input + cache_read (cached_tokens is a subset)" do
      chunk =
        ~s|data: {"id":"cmpl_1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":200,"total_tokens":1200,"prompt_tokens_details":{"cached_tokens":800}}}\n\n|

      events = run_with_chunk(chunk)

      # `:usage` is the first emitted event (before the
      # synthesized `:done`); look it up by pattern so the
      # test isn't sensitive to ordering.
      assert {:usage, usage} = Enum.find(events, &match?({:usage, _}, &1))
      # 1000 total - 800 cached = 200 new (the wire format
      # `input_tokens` semantic, matching the Anthropic client).
      assert usage.input_tokens == 200
      assert usage.cache_read_input_tokens == 800
      assert usage.output_tokens == 200
      assert usage.reasoning_tokens == 0
      # OpenAI has no cache-creation concept.
      assert usage.cache_creation_input_tokens == 0
      assert usage.total_tokens == 1200
    end

    test "captures reasoning_tokens from completion_tokens_details (subset of completion_tokens)" do
      chunk =
        ~s|data: {"id":"cmpl_2","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":50,"completion_tokens":200,"total_tokens":250,"completion_tokens_details":{"reasoning_tokens":150}}}\n\n|

      events = run_with_chunk(chunk)

      assert {:usage, usage} = Enum.find(events, &match?({:usage, _}, &1))
      # `output_tokens` is the full `completion_tokens` — the
      # reasoning subset is captured alongside, not subtracted.
      assert usage.output_tokens == 200
      assert usage.reasoning_tokens == 150
    end

    test "treats missing details sub-objects as 0" do
      chunk =
        ~s|data: {"id":"cmpl_3","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":50,"completion_tokens":200,"total_tokens":250}}\n\n|

      events = run_with_chunk(chunk)

      assert {:usage, usage} = Enum.find(events, &match?({:usage, _}, &1))
      assert usage.input_tokens == 50
      assert usage.cache_read_input_tokens == 0
      assert usage.cache_creation_input_tokens == 0
      assert usage.reasoning_tokens == 0
      assert usage.output_tokens == 200
    end

    test "clamps input_tokens to 0 when cached_tokens exceeds prompt_tokens" do
      # Defensive: a malformed payload where `cached_tokens` is
      # larger than `prompt_tokens` shouldn't produce a negative
      # `input_tokens` (the cost and chip views assume
      # non-negative counts).
      chunk =
        ~s|data: {"id":"cmpl_4","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":100,"completion_tokens":10,"total_tokens":110,"prompt_tokens_details":{"cached_tokens":150}}}\n\n|

      events = run_with_chunk(chunk)

      assert {:usage, usage} = Enum.find(events, &match?({:usage, _}, &1))
      assert usage.input_tokens == 0
      assert usage.cache_read_input_tokens == 150
    end
  end
end
