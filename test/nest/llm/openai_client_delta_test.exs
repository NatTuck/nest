defmodule Nest.LLM.OpenAIClient.DeltaTest do
  @moduledoc """
  Streaming-delta translation tests for `Nest.LLM.OpenAIClient`.

  Pulled out of `openai_client_test.exs` so the parent test file
  stays under the 500-line Credo cap while still covering every
  shape the OpenAI-compatible clients have to accept (reasoning-
  only deltas, combined `content`+`tool_calls` deltas, missing
  `finish_reason` keys, etc.).
  """
  use ExUnit.Case, async: true

  alias Nest.LLM.OpenAIClient

  describe "delta without finish_reason (OpenAI-compatible providers)" do
    # Some OpenAI-compatible providers (e.g. MiniMax reasoning,
    # DeepSeek R1) emit reasoning-only delta frames where the
    # choice has no `finish_reason` key at all. The translator
    # must accept these frames and emit the `{:thinking, text}`
    # event without crashing on the missing key.

    test "a reasoning-only delta translates to {:thinking, text} and does not crash" do
      # Mirrors the exact shape that the MiniMax provider sent
      # in the field report that motivated this fix.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "name" => "MiniMax AI",
              "role" => "assistant",
              "audio_content" => "",
              "reasoning_content" => "The user wants to",
              "reasoning_details" => [
                %{
                  "format" => "MiniMax-response-v1",
                  "id" => "reasoning-text-1",
                  "index" => 0,
                  "text" => "The user wants to",
                  "type" => "reasoning.text"
                }
              ]
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert {:thinking, "The user wants to"} in events
      # The frame carried no `finish_reason` key, so no
      # `:finish_reason` event should be emitted.
      refute Enum.any?(events, &match?({:finish_reason, _}, &1))
    end

    test "a delta with both content and tool_calls emits both events" do
      # Regression for the MiniMax-M3 "close think and start
      # tool call" frame: the server emits the closing
      # `</think>\n\n` text and the leading `tool_calls` array
      # in the SAME delta frame. The previous "first match wins"
      # ordering in `delta_events/1` silently dropped the tool
      # call when a content field was also present, so the user
      # saw only the think and the model appeared to "stop after
      # thinking". The fix combines events from every present
      # field — this frame must produce BOTH `{:text, _}` and
      # `{:tool_call_start, _}`.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "content" => "</think>\n\n",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_019f24ccd0c578a0ac24c493",
                  "type" => "function",
                  "function" => %{
                    "name" => "file-read",
                    "arguments" => "{\"path\":\"notes/subagents.md\"}"
                  }
                }
              ]
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert {:text, "</think>\n\n"} in events

      assert Enum.any?(events, fn
               {:tool_call_start, %{id: "call_019f24ccd0c578a0ac24c493", name: "file-read"}} ->
                 true

               _ ->
                 false
             end),
             "expected a :tool_call_start with the file-read id and name"

      assert Enum.any?(events, fn
               {:tool_call_delta, %{id: "call_019f24ccd0c578a0ac24c493", arguments_delta: args}} ->
                 args == "{\"path\":\"notes/subagents.md\"}"

               _ ->
                 false
             end),
             "expected a :tool_call_delta with the file-read path argument"
    end

    test "a delta with no content and no finish_reason ends the body :stream_incomplete" do
      # e.g. a provider sends a delta with only role/name and no
      # meaningful content, then closes without `data: [DONE]`. The
      # translator must not crash on the missing `finish_reason` key,
      # and the client must not synthesize a clean `:done` for a body
      # that produced no complete response.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "name" => "MiniMax AI",
              "role" => "assistant",
              "audio_content" => ""
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert events == [{:error, {:stream_incomplete, :no_terminator}}]
    end

    test "a delta with content, reasoning_content, and tool_calls emits all three" do
      # Three-field combination. The general walk must surface
      # text + thinking + tools in that order, not silently
      # drop the reasoning when both `content` and `tool_calls`
      # are present.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "content" => "visible",
              "reasoning_content" => "internal",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_three",
                  "type" => "function",
                  "function" => %{"name" => "file-read", "arguments" => "{}"}
                }
              ]
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert {:text, "visible"} in events
      assert {:thinking, "internal"} in events

      assert Enum.any?(events, fn
               {:tool_call_start, %{id: "call_three", name: "file-read"}} -> true
               _ -> false
             end)
    end

    test "a delta with content and refusal emits both events" do
      # Lock in the previously-dropped `content` + `refusal`
      # combination. Rare in practice but a provider that
      # emitted both fields in the same frame would have
      # silently lost the refusal.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "content" => "partial answer",
              "refusal" => "I cannot help with that."
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert {:text, "partial answer"} in events
      assert {:refusal, "I cannot help with that."} in events
    end
  end

  describe "vLLM tool_call seed shape (typhon provider)" do
    # vLLM (the typhon provider's backend) emits the tool_call
    # seed frame *without* a `function.arguments` field — only
    # `{id, type, index, function.name}`. Without a dedicated
    # seed clause, the seed fell through to the catch-all `[]`
    # in `tool_call_delta_events/1`, the lazy `tool_index_map`
    # was never seeded, and every subsequent by_index delta was
    # silently dropped — leaving `Client.finalize/2` with
    # `tool_calls: []` despite the provider returning
    # `finish_reason: "tool_calls"`.

    test "seed frame with no `arguments` field emits :tool_call_start with id and name" do
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "id" => "chatcmpl-tool-be1743ced731ac03",
                  "type" => "function",
                  "index" => 0,
                  "function" => %{"name" => "get_weather"}
                }
              ]
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert Enum.any?(events, fn
               {:tool_call_start, %{id: "chatcmpl-tool-be1743ced731ac03", name: "get_weather"}} ->
                 true

               _ ->
                 false
             end),
             "expected a :tool_call_start with the typhon tool call id and `get_weather` name"

      refute Enum.any?(events, &match?({:tool_call_delta, _}, &1))
    end
  end

  defp run_with_chunk(chunk) do
    parent = self()

    spawn_link(fn ->
      send(parent, {:req_chunk, chunk})
      send(parent, :req_done)
    end)

    stream = OpenAIClient.consume_sse_from_mailbox()
    Enum.to_list(stream)
  end
end
