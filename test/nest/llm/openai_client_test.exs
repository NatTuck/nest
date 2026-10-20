defmodule Nest.LLM.OpenAIClientTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.OpenAIClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.Tool
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User

  defp user_msg(text), do: {:user, %User{index: 1, parts: [%Part.Text{text: text}]}}
  defp sys_msg(index, text), do: {:system, %System{index: index, parts: [%Part.Text{text: text}]}}

  describe "format_request_payload/2" do
    test "emits model, messages, stream, and stream_options.include_usage" do
      req = %RunRequest{
        model: "gpt-4o",
        messages: [user_msg("hi")]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["model"] == "gpt-4o"
      assert payload["stream"] == true
      assert payload["stream_options"] == %{"include_usage" => true}
      assert payload["messages"] == [%{"role" => "user", "content" => "hi"}]
      refute Map.has_key?(payload, "temperature")
      refute Map.has_key?(payload, "max_tokens")
      refute Map.has_key?(payload, "top_p")
      refute Map.has_key?(payload, "tools")
      assert payload["tool_choice"] == "auto"
    end

    test "applies the DeepSeek flash top_p/max_tokens defaults to flash models only" do
      for model <- ["deepseek-v4-flash", "DeepSeek-V4-Flash-2026", "deepseek-flash"] do
        payload = OpenAIClient.format_request_payload(%RunRequest{model: model}, [])

        assert payload["top_p"] == 0.95
        assert payload["max_tokens"] == 32_000
      end

      # Models outside the DeepSeek-flash family get neither default.
      for model <- ["deepseek-reasoner", "deepseek-v3", "qwen3.5-plus"] do
        payload = OpenAIClient.format_request_payload(%RunRequest{model: model}, [])

        refute Map.has_key?(payload, "top_p")
        refute Map.has_key?(payload, "max_tokens")
      end
    end

    test "keeps system messages at their positions in the wire messages" do
      # A leading {:system, _} message maps into the messages array.
      leading =
        OpenAIClient.format_request_payload(%RunRequest{messages: [sys_msg(0, "be brief")]}, [])

      assert leading["messages"] == [
               %{"role" => "system", "content" => "be brief"}
             ]

      # A late {:system, _} reminder is preserved at its position.
      late =
        OpenAIClient.format_request_payload(
          %RunRequest{
            messages: [
              sys_msg(0, "be brief"),
              user_msg("hi"),
              sys_msg(2, "2 rounds left")
            ]
          },
          []
        )

      assert late["messages"] == [
               %{"role" => "system", "content" => "be brief"},
               %{"role" => "user", "content" => "hi"},
               %{"role" => "system", "content" => "2 rounds left"}
             ]

      # System messages already in the request history are preserved.
      history =
        OpenAIClient.format_request_payload(
          %RunRequest{
            messages: [
              sys_msg(0, "be brief"),
              user_msg("hi")
            ]
          },
          []
        )

      assert history["messages"] == [
               %{"role" => "system", "content" => "be brief"},
               %{"role" => "user", "content" => "hi"}
             ]
    end

    test "omits the system message when the messages array has none" do
      req = %RunRequest{messages: [user_msg("hi")]}
      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [%{"role" => "user", "content" => "hi"}]
      assert Enum.all?(payload["messages"], &(&1["role"] != "system"))
    end

    test "emits tools as the OpenAI function-tool shape" do
      tool = %Tool{
        name: "shell-cmd",
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
                   "name" => "shell-cmd",
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
             parts: [
               %Part.Text{text: "calling shell"},
               %Part.ToolUse{id: "call_1", name: "shell-cmd", arguments: %{"command" => "ls"}}
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
                       "name" => "shell-cmd",
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
             parts: [
               %Part.ToolResult{tool_call_id: "call_1", name: "shell-cmd", content: "out1"},
               %Part.ToolResult{tool_call_id: "call_2", name: "file-read", content: "out2"}
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

    test "uses a placeholder for blank content across roles" do
      # A tool-call-only assistant message still gets non-empty content.
      tool_call_only =
        OpenAIClient.format_request_payload(
          %RunRequest{
            messages: [
              {:assistant,
               %Assistant{
                 index: 2,
                 parts: [
                   %Part.ToolUse{
                     id: "call_1",
                     name: "shell-cmd",
                     arguments: %{"command" => "ls"}
                   }
                 ]
               }}
            ]
          },
          []
        )

      assert tool_call_only["messages"] == [
               %{
                 "role" => "assistant",
                 "content" => " ",
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "type" => "function",
                     "function" => %{"name" => "shell-cmd", "arguments" => ~s({"command":"ls"})}
                   }
                 ]
               }
             ]

      # An assistant message with no parts at all.
      empty_assistant =
        OpenAIClient.format_request_payload(
          %RunRequest{
            messages: [{:assistant, %Assistant{index: 2, parts: []}}]
          },
          []
        )

      assert empty_assistant["messages"] == [%{"role" => "assistant", "content" => " "}]

      # Empty system and user content.
      empty_system_and_user =
        OpenAIClient.format_request_payload(
          %RunRequest{
            messages: [
              {:system, %Nest.Messages.System{index: 0, parts: []}},
              {:user, %Nest.Messages.User{index: 1, parts: []}}
            ]
          },
          []
        )

      assert empty_system_and_user["messages"] == [
               %{"role" => "system", "content" => " "},
               %{"role" => "user", "content" => " "}
             ]

      # Empty tool-result content.
      empty_tool_result =
        OpenAIClient.format_request_payload(
          %RunRequest{
            messages: [
              {:tool,
               %Nest.Messages.Tool{
                 index: 3,
                 parts: [
                   %Part.ToolResult{tool_call_id: "call_1", name: "shell-cmd", content: ""},
                   %Part.ToolResult{tool_call_id: "call_2", name: "file-read", content: nil}
                 ]
               }}
            ]
          },
          []
        )

      assert empty_tool_result["messages"] == [
               %{"role" => "tool", "tool_call_id" => "call_1", "content" => " "},
               %{"role" => "tool", "tool_call_id" => "call_2", "content" => " "}
             ]
    end

    test "passes through temperature, max_tokens, top_p when set" do
      # The model matches the DeepSeek-flash default rule, so explicit
      # values must win over the defaults.
      payload =
        OpenAIClient.format_request_payload(
          %RunRequest{
            model: "deepseek-v4-flash",
            temperature: 0.3,
            max_tokens: 1024,
            top_p: 0.9
          },
          []
        )

      assert payload["temperature"] == 0.3
      assert payload["max_tokens"] == 1024
      assert payload["top_p"] == 0.9
    end

    test "emits thinking fields according to thinking_effort" do
      for {level, expected} <- [{:low, "low"}, {:medium, "medium"}, {:high, "high"}] do
        payload =
          OpenAIClient.format_request_payload(%RunRequest{thinking_effort: level}, [])

        assert payload["reasoning_effort"] == expected
        refute Map.has_key?(payload, "chat_template_kwargs")
      end

      # :xhigh maps to high for OpenAI-compatible servers.
      xhigh = OpenAIClient.format_request_payload(%RunRequest{thinking_effort: :xhigh}, [])

      assert xhigh["reasoning_effort"] == "high"

      # :off disables thinking via chat_template_kwargs instead.
      off = OpenAIClient.format_request_payload(%RunRequest{thinking_effort: :off}, [])

      assert off["chat_template_kwargs"] == %{"enable_thinking" => false}
      refute Map.has_key?(off, "reasoning_effort")

      # A nil effort emits no thinking fields at all.
      unset = OpenAIClient.format_request_payload(%RunRequest{thinking_effort: nil}, [])

      refute Map.has_key?(unset, "reasoning_effort")
      refute Map.has_key?(unset, "chat_template_kwargs")
    end

    test "translates tool_choice to the OpenAI shape" do
      for {choice, expected} <- [
            {:auto, "auto"},
            {:none, "none"},
            {:required, "required"},
            {{:tool, "shell-cmd"},
             %{"type" => "function", "function" => %{"name" => "shell-cmd"}}}
          ] do
        payload = OpenAIClient.format_request_payload(%RunRequest{tool_choice: choice}, [])
        assert payload["tool_choice"] == expected
      end
    end
  end

  describe "error handling" do
    test "parses synthetic error chunks into {:error, {type, status, body}} events" do
      http_error_chunk =
        "data: " <>
          Jason.encode!(%{error: "http_error", status: 429, body: "rate limited"}) <> "\n\n"

      http_events = run_with_chunk(http_error_chunk)

      assert {:error, {"http_error", 429, "rate limited"}} in http_events

      # A transport-level failure carries `:transport` where a status would be.
      request_failed_chunk =
        "data: " <>
          Jason.encode!(%{error: "request_failed", status: nil, body: "connection refused"}) <>
          "\n\n"

      transport_events = run_with_chunk(request_failed_chunk)

      assert {:error, {"request_failed", :transport, "connection refused"}} in transport_events
    end
  end

  describe "normalize_endpoint/2" do
    test "normalizes base URLs and endpoints" do
      # Appends the endpoint to a clean base URL.
      assert OpenAIClient.normalize_endpoint("https://api.example.com/v1", "/chat/completions") ==
               "https://api.example.com/v1/chat/completions"

      # Strips a trailing slash before appending.
      assert OpenAIClient.normalize_endpoint("https://api.example.com/v1/", "/chat/completions") ==
               "https://api.example.com/v1/chat/completions"

      # A /v1 suffix is kept rather than stripped twice.
      assert OpenAIClient.normalize_endpoint(
               "https://token-plan.example.com/apps/anthropic/v1",
               "/chat/completions"
             ) == "https://token-plan.example.com/apps/anthropic/v1/chat/completions"

      # Strips a duplicate endpoint before appending.
      assert OpenAIClient.normalize_endpoint(
               "https://api.example.com/v1/chat/completions",
               "/chat/completions"
             ) == "https://api.example.com/v1/chat/completions"

      # Strips a duplicate endpoint that has a trailing slash.
      assert OpenAIClient.normalize_endpoint(
               "https://api.example.com/v1/chat/completions/",
               "/chat/completions"
             ) == "https://api.example.com/v1/chat/completions"
    end
  end

  describe "synthesized :done when the body has no [DONE] frame" do
    # The OpenAI wire protocol requires the server to send
    # `data: [DONE]\n\n` at end-of-stream, but providers sometimes close
    # without it. We treat the stream as complete when a `finish_reason`
    # was seen and synthesize the `{:done, _}` ourselves: without it
    # `StreamConsumer` returns `response: nil`, which the dispatcher
    # misclassifies as a user-initiated stop. If neither `[DONE]` nor a
    # `finish_reason` arrived, the connection dropped mid-response and
    # the client flags `{:stream_incomplete, :no_terminator}` instead.

    test "synthesizes a :done event when a finish_reason was seen without a [DONE] frame" do
      # The chunk streams content and a `finish_reason`, then closes
      # without `data: [DONE]`.
      delta_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "content" => "Hello"},
            "finish_reason" => "stop"
          }
        ]
      }

      chunk = "data: " <> Jason.encode!(delta_frame) <> "\n\n"
      events = run_with_chunk(chunk)

      assert {:text, "Hello"} in events
      assert {:finish_reason, "stop"} in events

      # The synthesized terminal event. Its %RunResponse{} is empty so
      # `normalize_response/2` populates text/thinking/etc. from the
      # accumulator.
      assert {:done, %{response: %RunResponse{text: nil}}} in events
    end

    test "flags :stream_incomplete when neither [DONE] nor finish_reason arrived" do
      # Mirrors the MiniMax field report: the provider streamed thinking
      # content and then closed the connection with no terminator at all.
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
      assert {:error, {:stream_incomplete, :no_terminator}} in events
      refute Enum.any?(events, &match?({:done, _}, &1))
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

    test "an empty body (only :req_done) is :stream_incomplete" do
      # No chunks at all and no terminator: the connection dropped
      # before any response arrived. Previously this synthesized a
      # `:done` with an empty RunResponse, which masqueraded as a
      # complete (empty) reply.
      events = run_with_chunk("")

      assert events == [{:error, {:stream_incomplete, :no_terminator}}]
    end
  end

  describe "idle watchdog" do
    test "emits {:stream_idle_timeout, ms} and kills the worker when no chunk arrives" do
      worker =
        spawn_link(fn ->
          receive do
            :never -> :ok
          end
        end)

      ref = Process.monitor(worker)

      events =
        OpenAIClient.consume_sse_from_mailbox(worker: worker, timeout: 50) |> Enum.to_list()

      assert events == [{:error, {:stream_idle_timeout, 50}}]
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
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
