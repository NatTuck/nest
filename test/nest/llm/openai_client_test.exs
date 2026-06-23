defmodule Nest.LLM.OpenAIClientTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.OpenAIClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.Tool
  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User

  describe "format_request_payload/2" do
    test "emits model, messages, stream, and stream_options.include_usage" do
      req = %RunRequest{
        model: "gpt-4o",
        messages: [
          {:user, %User{index: 1, content: "hi"}}
        ]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["model"] == "gpt-4o"
      assert payload["stream"] == true
      assert payload["stream_options"] == %{"include_usage" => true}
      assert payload["messages"] == [%{"role" => "user", "content" => "hi"}]
      refute Map.has_key?(payload, "temperature")
      refute Map.has_key?(payload, "tools")
      assert payload["tool_choice"] == "auto"
    end

    test "prepends a system message when request.system_prompt is set" do
      req = %RunRequest{system_prompt: "be brief", messages: []}
      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{"role" => "system", "content" => "be brief"}
             ]
    end

    test "omits the system message when request.system_prompt is nil" do
      req = %RunRequest{messages: [{:user, %User{index: 1, content: "hi"}}]}
      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [%{"role" => "user", "content" => "hi"}]
    end

    test "emits tools as the OpenAI function-tool shape" do
      tool = %Tool{
        name: "shell_cmd",
        description: "run a command",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{"command" => %{"type" => "string"}},
          "required" => ["command"]
        }
      }

      payload =
        OpenAIClient.format_request_payload(%RunRequest{tools: [tool]}, [])

      assert payload["tools"] == [
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "shell_cmd",
                   "description" => "run a command",
                   "parameters" => %{
                     "type" => "object",
                     "properties" => %{"command" => %{"type" => "string"}},
                     "required" => ["command"]
                   }
                 }
               }
             ]
    end

    test "translates assistant messages with tool calls to the OpenAI shape" do
      req = %RunRequest{
        messages: [
          {:assistant,
           %Assistant{
             index: 2,
             content: "calling shell",
             tool_calls: [
               %ToolCall{id: "call_1", name: "shell_cmd", arguments: %{"command" => "ls"}}
             ]
           }}
        ]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{
                 "role" => "assistant",
                 "content" => "calling shell",
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "type" => "function",
                     "function" => %{
                       "name" => "shell_cmd",
                       "arguments" => ~s({"command":"ls"})
                     }
                   }
                 ]
               }
             ]
    end

    test "expands a tool message into one wire message per tool result" do
      req = %RunRequest{
        messages: [
          {:tool,
           %Nest.Messages.Tool{
             index: 3,
             tool_results: [
               %ToolResult{tool_call_id: "call_1", name: "shell_cmd", content: "out1"},
               %ToolResult{tool_call_id: "call_2", name: "read_file", content: "out2"}
             ]
           }}
        ]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{"role" => "tool", "tool_call_id" => "call_1", "content" => "out1"},
               %{"role" => "tool", "tool_call_id" => "call_2", "content" => "out2"}
             ]
    end

    test "passes through temperature, max_tokens, top_p when set" do
      payload =
        OpenAIClient.format_request_payload(
          %RunRequest{temperature: 0.3, max_tokens: 1024, top_p: 0.9},
          []
        )

      assert payload["temperature"] == 0.3
      assert payload["max_tokens"] == 1024
      assert payload["top_p"] == 0.9
    end

    test "translates tool_choice to the OpenAI shape" do
      for {choice, expected} <- [
            {:auto, "auto"},
            {:none, "none"},
            {:required, "required"},
            {{:tool, "shell_cmd"},
             %{"type" => "function", "function" => %{"name" => "shell_cmd"}}}
          ] do
        payload = OpenAIClient.format_request_payload(%RunRequest{tool_choice: choice}, [])
        assert payload["tool_choice"] == expected
      end
    end

    test "drops the system message key from the request when no system message is in history" do
      req = %RunRequest{
        messages: [
          {:user, %User{index: 1, content: "hi"}}
        ]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert Enum.all?(payload["messages"], &(&1["role"] != "system"))
    end

    test "preserves system messages already in the request history" do
      req = %RunRequest{
        messages: [
          {:system, %System{index: 0, content: "be brief"}},
          {:user, %User{index: 1, content: "hi"}}
        ]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{"role" => "system", "content" => "be brief"},
               %{"role" => "user", "content" => "hi"}
             ]
    end
  end

  describe "error handling" do
    test "parses synthetic http_error chunk into {:error, {type, status, body}} event" do
      error_chunk =
        "data: " <>
          Jason.encode!(%{error: "http_error", status: 429, body: "rate limited"}) <> "\n\n"

      events = run_with_chunk(error_chunk)

      assert {:error, {"http_error", 429, "rate limited"}} in events
    end

    test "parses synthetic request_failed chunk into {:error, _} event" do
      error_chunk =
        "data: " <>
          Jason.encode!(%{error: "request_failed", status: nil, body: "connection refused"}) <>
          "\n\n"

      events = run_with_chunk(error_chunk)

      assert {:error, "request_failed"} in events
    end
  end

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
  end

  describe "synthesized :done when the body has no [DONE] frame" do
    # The OpenAI wire protocol requires the server to send
    # `data: [DONE]\n\n` at end-of-stream, but providers
    # sometimes close the connection without it (notably
    # reasoning-only responses from some OpenAI-compatible
    # endpoints, where the server's response loop finishes
    # without emitting a final frame). Without the
    # synthesis, the `StreamConsumer` returns `response: nil`,
    # which the dispatcher misclassifies as a user-initiated
    # stop and routes through `StopHandler` — tagging the
    # partial with `metadata: %{"stopped_by_user" => true}`
    # and skipping the response log. The fix synthesizes a
    # `{:done, _}` event so the stream goes through the normal
    # `handle_new_response/3` path, which broadcasts the
    # response log and finalizes with the correct metadata.

    test "synthesizes a :done event when the body ends without a [DONE] frame" do
      # The chunk only has a reasoning delta — no `data: [DONE]`.
      # This mirrors the MiniMax field report exactly: the
      # provider streamed thinking content and then closed the
      # connection.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "name" => "MiniMax AI",
              "role" => "assistant",
              "reasoning_content" => "The user wants to know the project layout."
            }
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert {:thinking, "The user wants to know the project layout."} in events
      # The synthesized terminal event. The carried
      # %RunResponse{} is empty so `normalize_response/2`
      # populates text/thinking/etc. from the accumulator.
      assert {:done, %{response: %RunResponse{}}} in events
    end

    test "does not synthesize a second :done when the body already had one" do
      # Normal happy path: the body has a final `data: [DONE]`.
      # The translator's `{:done, _}` event (with
      # `stop_reason: "stop"`) must not be duplicated.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", content: "Hello"},
            "finish_reason" => "stop"
          }
        ]
      }

      chunk =
        "data: " <>
          Jason.encode!(delta_frame) <>
          "\n\n" <>
          "data: [DONE]\n\n"

      events = run_with_chunk(chunk)

      # Exactly one `:done` event (the one from `[DONE]`),
      # not two. The carried `%RunResponse{stop_reason: "stop"}`
      # is the original; we don't synthesize a second one.
      done_events = Enum.filter(events, &match?({:done, _}, &1))
      assert length(done_events) == 1

      assert {:done, %{response: %RunResponse{stop_reason: "stop"}}} in events
    end

    test "the synthesized :done carries an empty RunResponse that normalize_response can populate" do
      # The synthesized `%RunResponse{}` has no text, thinking,
      # tool_calls, thinking_signature, or usage. The
      # chat-task-side `normalize_response/2` is responsible
      # for merging in the accumulator's values. This test
      # pins the contract: the synthesized event is empty
      # *by design* — the merge happens downstream.
      # empty body — only :req_done, no chunks
      chunk = ""
      events = run_with_chunk(chunk)

      assert events == [{:done, %{response: %RunResponse{}}}]
      refute Enum.any?(events, &match?({:text, _}, &1))
      refute Enum.any?(events, &match?({:thinking, _}, &1))
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
