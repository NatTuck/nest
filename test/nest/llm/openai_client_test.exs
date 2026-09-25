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

    test "applies DeepSeek flash top_p/max_tokens defaults when unset" do
      for model <- ["deepseek-v4-flash", "DeepSeek-V4-Flash-2026", "deepseek-flash"] do
        payload = OpenAIClient.format_request_payload(%RunRequest{model: model}, [])

        assert payload["top_p"] == 0.95
        assert payload["max_tokens"] == 32_000
      end
    end

    test "does not apply the DeepSeek flash defaults to other models" do
      for model <- ["deepseek-reasoner", "deepseek-v3", "qwen3.5-plus"] do
        payload = OpenAIClient.format_request_payload(%RunRequest{model: model}, [])

        refute Map.has_key?(payload, "top_p")
        refute Map.has_key?(payload, "max_tokens")
      end
    end

    test "maps a leading {:system, _} message in the messages array" do
      req = %RunRequest{
        messages: [sys_msg(0, "be brief")]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{"role" => "system", "content" => "be brief"}
             ]
    end

    test "preserves a late {:system, _} reminder at its position" do
      req = %RunRequest{
        messages: [
          sys_msg(0, "be brief"),
          user_msg("hi"),
          sys_msg(2, "2 rounds left")
        ]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{"role" => "system", "content" => "be brief"},
               %{"role" => "user", "content" => "hi"},
               %{"role" => "system", "content" => "2 rounds left"}
             ]
    end

    test "omits the system message when the messages array has none" do
      req = %RunRequest{messages: [user_msg("hi")]}
      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [%{"role" => "user", "content" => "hi"}]
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

    test "uses a placeholder for a tool-call-only assistant message" do
      req = %RunRequest{
        messages: [
          {:assistant,
           %Assistant{
             index: 2,
             parts: [
               %Part.ToolUse{id: "call_1", name: "shell-cmd", arguments: %{"command" => "ls"}}
             ]
           }}
        ]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [
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
    end

    test "uses a placeholder for an empty assistant message" do
      req = %RunRequest{
        messages: [{:assistant, %Assistant{index: 2, parts: []}}]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [%{"role" => "assistant", "content" => " "}]
    end

    test "uses a placeholder for empty system and user content" do
      req = %RunRequest{
        messages: [
          {:system, %Nest.Messages.System{index: 0, parts: []}},
          {:user, %Nest.Messages.User{index: 1, parts: []}}
        ]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{"role" => "system", "content" => " "},
               %{"role" => "user", "content" => " "}
             ]
    end

    test "uses a placeholder for empty tool-result content" do
      req = %RunRequest{
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
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert payload["messages"] == [
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

    test "emits reasoning_effort for enabled thinking levels" do
      for {level, expected} <- [{:low, "low"}, {:medium, "medium"}, {:high, "high"}] do
        payload =
          OpenAIClient.format_request_payload(%RunRequest{thinking_effort: level}, [])

        assert payload["reasoning_effort"] == expected
        refute Map.has_key?(payload, "chat_template_kwargs")
      end
    end

    test "maps :xhigh to high for OpenAI-compatible servers" do
      payload = OpenAIClient.format_request_payload(%RunRequest{thinking_effort: :xhigh}, [])

      assert payload["reasoning_effort"] == "high"
    end

    test "disables thinking via chat_template_kwargs for :off" do
      payload = OpenAIClient.format_request_payload(%RunRequest{thinking_effort: :off}, [])

      assert payload["chat_template_kwargs"] == %{"enable_thinking" => false}
      refute Map.has_key?(payload, "reasoning_effort")
    end

    test "emits no thinking fields when thinking_effort is nil" do
      payload = OpenAIClient.format_request_payload(%RunRequest{thinking_effort: nil}, [])

      refute Map.has_key?(payload, "reasoning_effort")
      refute Map.has_key?(payload, "chat_template_kwargs")
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

    test "drops the system message key from the request when no system message is in history" do
      req = %RunRequest{
        messages: [user_msg("hi")]
      }

      payload = OpenAIClient.format_request_payload(req, [])

      assert Enum.all?(payload["messages"], &(&1["role"] != "system"))
    end

    test "preserves system messages already in the request history" do
      req = %RunRequest{
        messages: [
          sys_msg(0, "be brief"),
          user_msg("hi")
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

    test "parses synthetic request_failed chunk into {:error, {type, :transport, body}} event" do
      error_chunk =
        "data: " <>
          Jason.encode!(%{error: "request_failed", status: nil, body: "connection refused"}) <>
          "\n\n"

      events = run_with_chunk(error_chunk)

      assert {:error, {"request_failed", :transport, "connection refused"}} in events
    end
  end

  describe "normalize_endpoint/2" do
    test "appends endpoint to clean base URL" do
      assert OpenAIClient.normalize_endpoint("https://api.example.com/v1", "/chat/completions") ==
               "https://api.example.com/v1/chat/completions"
    end

    test "strips trailing slash before appending" do
      assert OpenAIClient.normalize_endpoint("https://api.example.com/v1/", "/chat/completions") ==
               "https://api.example.com/v1/chat/completions"
    end

    test "strips /v1 suffix before appending endpoint" do
      assert OpenAIClient.normalize_endpoint(
               "https://token-plan.example.com/apps/anthropic/v1",
               "/chat/completions"
             ) == "https://token-plan.example.com/apps/anthropic/v1/chat/completions"
    end

    test "strips duplicate endpoint before appending" do
      assert OpenAIClient.normalize_endpoint(
               "https://api.example.com/v1/chat/completions",
               "/chat/completions"
             ) == "https://api.example.com/v1/chat/completions"
    end

    test "strips duplicate endpoint with trailing slash" do
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
