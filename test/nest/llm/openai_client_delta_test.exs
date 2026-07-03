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
  alias Nest.LLM.RunResponse

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

    test "a delta with both reasoning_content and finish_reason emits both events" do
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "stop",
            "delta" => %{
              "role" => "assistant",
              "reasoning_content" => "thinking..."
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert {:thinking, "thinking..."} in events
      assert {:finish_reason, "stop"} in events
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
                    "name" => "read_file",
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
               {:tool_call_start, %{id: "call_019f24ccd0c578a0ac24c493", name: "read_file"}} ->
                 true

               _ ->
                 false
             end),
             "expected a :tool_call_start with the read_file id and name"

      assert Enum.any?(events, fn
               {:tool_call_delta, %{id: "call_019f24ccd0c578a0ac24c493", arguments_delta: args}} ->
                 args == "{\"path\":\"notes/subagents.md\"}"

               _ ->
                 false
             end),
             "expected a :tool_call_delta with the read_file path argument"
    end

    test "a delta with only tool_calls still emits the tool events (no content)" do
      # The standard OpenAI path: a delta carries only
      # `tool_calls` with no `content`. The combined-delta fix
      # must not regress this case.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_only",
                  "type" => "function",
                  "function" => %{"name" => "shell_cmd", "arguments" => "{}"}
                }
              ]
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert Enum.any?(events, fn
               {:tool_call_start, %{id: "call_only", name: "shell_cmd"}} -> true
               _ -> false
             end)

      refute Enum.any?(events, &match?({:text, _}, &1))
    end

    test "a delta with neither content nor reasoning_content and no finish_reason emits only a synthesized :done" do
      # e.g. a provider sends a delta with only role/name and no
      # meaningful content. The translator must not crash on the
      # missing `finish_reason` key. Since the body has no
      # `data: [DONE]` frame either, `handle_req_done_openai/1`
      # synthesizes a `{:done, _}` so the chat task finalizes
      # the response cleanly via the normal-completion path
      # (which broadcasts the response log). The accumulated
      # `text`/`thinking`/etc. are all nil because nothing was
      # streamed — the synthesized `RunResponse` is empty.
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

      # No content/thinking/finish_reason events — the only
      # output is the synthesized `:done` so the chat task
      # routes through `handle_new_response/3` instead of
      # being misclassified as a user-initiated stop.
      assert events == [{:done, %{response: %RunResponse{}}}]
    end

    test "a delta with both content and reasoning_content emits both events" do
      # Lock in the fix for the previously-dropped combination.
      # DeepSeek R1-style reasoning models can emit
      # `reasoning_content` alongside `content` in the same
      # frame; the walk must surface both, not silently drop
      # the reasoning.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "content" => "actual text",
              "reasoning_content" => "thinking text"
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert {:text, "actual text"} in events
      assert {:thinking, "thinking text"} in events
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
                  "function" => %{"name" => "read_file", "arguments" => "{}"}
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
               {:tool_call_start, %{id: "call_three", name: "read_file"}} -> true
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

  describe "delta field combinations (exhaustive)" do
    # The general walk covers all 16 combinations of
    # {content, reasoning_content, refusal, tool_calls}
    # (minus the all-empty case). This parametrized test
    # pins the event presence for every combination so
    # future refactors don't accidentally drop a field
    # again. The booleans are unquoted into each test body
    # so the test function has direct access to them.
    combinations =
      for c <- [true, false],
          r <- [true, false],
          u <- [true, false],
          t <- [true, false],
          not (c == false and r == false and u == false and t == false),
          do: {c, r, u, t}

    for {c?, r?, u?, t?} <- combinations do
      @c c?
      @r r?
      @u u?
      @t t?

      test "combination c=#{c?} r=#{r?} u=#{u?} t=#{t?}" do
        delta = %{}
        delta = if @c, do: Map.put(delta, "content", "t"), else: delta
        delta = if @r, do: Map.put(delta, "reasoning_content", "r"), else: delta
        delta = if @u, do: Map.put(delta, "refusal", "u"), else: delta

        delta =
          if @t,
            do:
              Map.put(delta, "tool_calls", [
                %{
                  "index" => 0,
                  "id" => "call_x",
                  "type" => "function",
                  "function" => %{"name" => "read_file", "arguments" => "{}"}
                }
              ]),
            else: delta

        delta_frame = %{
          "choices" => [%{"index" => 0, "delta" => delta}]
        }

        chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
        events = run_with_chunk(chunk)

        if @c,
          do: assert({:text, "t"} in events, "expected :text event for #{inspect(delta)}"),
          else: refute({:text, "t"} in events, "unexpected :text event for #{inspect(delta)}")

        if @r,
          do:
            assert({:thinking, "r"} in events, "expected :thinking event for #{inspect(delta)}"),
          else:
            refute({:thinking, "r"} in events, "unexpected :thinking event for #{inspect(delta)}")

        if @u,
          do: assert({:refusal, "u"} in events, "expected :refusal event for #{inspect(delta)}"),
          else:
            refute({:refusal, "u"} in events, "unexpected :refusal event for #{inspect(delta)}")

        if @t,
          do:
            assert(
              Enum.any?(events, &match?({:tool_call_start, _}, &1)),
              "expected :tool_call_start event for #{inspect(delta)}"
            ),
          else:
            refute(
              Enum.any?(events, &match?({:tool_call_start, _}, &1)),
              "unexpected :tool_call_start event for #{inspect(delta)}"
            )
      end
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
