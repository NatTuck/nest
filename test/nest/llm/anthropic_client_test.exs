defmodule Nest.LLM.AnthropicClientTest do
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.Tool, as: LLMTool
  alias Nest.Messages.Assistant
  alias Nest.Messages.Tool, as: ToolMessage
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User

  setup :verify_on_exit!

  describe "format_request_payload/2" do
    test "emits model, max_tokens, messages, and stream: true" do
      req = %RunRequest{
        model: "claude-3-opus-20240229",
        messages: [
          {:user, %User{index: 1, content: "hi"}}
        ]
      }

      payload = AnthropicClient.format_request_payload(req, [])

      assert payload["model"] == "claude-3-opus-20240229"
      assert payload["stream"] == true
      assert payload["max_tokens"] == 4096
      assert payload["messages"] == [%{"role" => "user", "content" => "hi"}]
      refute Map.has_key?(payload, "system")
      refute Map.has_key?(payload, "tools")
    end

    test "lifts request.system_prompt into the top-level system field" do
      req = %RunRequest{
        system_prompt: "be brief",
        messages: [{:user, %User{index: 1, content: "hi"}}]
      }

      payload = AnthropicClient.format_request_payload(req, [])

      assert payload["system"] == "be brief"
      assert payload["messages"] == [%{"role" => "user", "content" => "hi"}]
    end

    test "omits the system field entirely when system_prompt is nil" do
      req = %RunRequest{messages: [{:user, %User{index: 1, content: "hi"}}]}

      payload = AnthropicClient.format_request_payload(req, [])

      refute Map.has_key?(payload, "system")
    end

    test "emits tools in the Anthropic shape" do
      tool = %LLMTool{
        name: "shell_cmd",
        description: "run a command",
        parameters_schema: %{
          "type" => "object",
          "properties" => %{"command" => %{"type" => "string"}},
          "required" => ["command"]
        }
      }

      payload = AnthropicClient.format_request_payload(%RunRequest{tools: [tool]}, [])

      assert payload["tools"] == [
               %{
                 "name" => "shell_cmd",
                 "description" => "run a command",
                 "input_schema" => %{
                   "type" => "object",
                   "properties" => %{"command" => %{"type" => "string"}},
                   "required" => ["command"]
                 }
               }
             ]
    end

    test "rebuilds assistant content blocks preserving text, thinking + signature, and tool_use order" do
      req = %RunRequest{
        messages: [
          {:assistant,
           %Assistant{
             index: 2,
             content: "I'll run that for you",
             thinking: "let me think...",
             thinking_signature: "sig_abc",
             tool_calls: [
               %ToolCall{id: "toolu_1", name: "shell_cmd", arguments: %{"command" => "ls"}}
             ]
           }}
        ]
      }

      payload = AnthropicClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "text", "text" => "I'll run that for you"},
                   %{
                     "type" => "thinking",
                     "thinking" => "let me think...",
                     "signature" => "sig_abc"
                   },
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_1",
                     "name" => "shell_cmd",
                     "input" => %{"command" => "ls"}
                   }
                 ]
               }
             ]
    end

    test "omits the thinking block entirely when thinking is nil" do
      req = %RunRequest{
        messages: [
          {:assistant,
           %Assistant{
             index: 2,
             content: "plain text",
             tool_calls: [
               %ToolCall{id: "toolu_1", name: "shell_cmd", arguments: %{}}
             ]
           }}
        ]
      }

      payload = AnthropicClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "text", "text" => "plain text"},
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_1",
                     "name" => "shell_cmd",
                     "input" => %{}
                   }
                 ]
               }
             ]
    end

    test "emits thinking block without signature when the assistant has no signature in metadata" do
      req = %RunRequest{
        messages: [
          {:assistant,
           %Assistant{
             index: 2,
             content: nil,
             thinking: "just thinking",
             tool_calls: nil
           }}
        ]
      }

      payload = AnthropicClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "thinking", "thinking" => "just thinking"}
                 ]
               }
             ]
    end

    test "round-trips a stored Assistant through AnthropicClient.format_request_payload/2" do
      # Simulates the second turn of a multi-turn conversation: an
      # Assistant struct that was persisted from the previous turn
      # (with thinking + signature + tool call) is re-serialized
      # for the next request. The signature must travel on the
      # thinking block, the tool_use block must keep its id and
      # input, and the order must match Anthropic's content-block
      # order convention.
      stored = %Assistant{
        index: 4,
        content: "I'll run that for you",
        thinking: "let me check",
        thinking_signature: "sig_round_trip_42",
        tool_calls: [%ToolCall{id: "toolu_9", name: "shell_cmd", arguments: %{"command" => "ls"}}]
      }

      payload =
        AnthropicClient.format_request_payload(%RunRequest{messages: [{:assistant, stored}]}, [])

      assert payload["messages"] == [
               %{
                 "role" => "assistant",
                 "content" => [
                   %{"type" => "text", "text" => "I'll run that for you"},
                   %{
                     "type" => "thinking",
                     "thinking" => "let me check",
                     "signature" => "sig_round_trip_42"
                   },
                   %{
                     "type" => "tool_use",
                     "id" => "toolu_9",
                     "name" => "shell_cmd",
                     "input" => %{"command" => "ls"}
                   }
                 ]
               }
             ]
    end

    test "translates tool results to a user-role message with tool_result content blocks" do
      req = %RunRequest{
        messages: [
          {:tool,
           %ToolMessage{
             index: 3,
             tool_results: [
               %ToolResult{
                 tool_call_id: "toolu_1",
                 name: "shell_cmd",
                 content: "out1",
                 is_error: false
               },
               %ToolResult{
                 tool_call_id: "toolu_2",
                 name: "read_file",
                 content: "boom",
                 is_error: true
               }
             ]
           }}
        ]
      }

      payload = AnthropicClient.format_request_payload(req, [])

      assert payload["messages"] == [
               %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_1",
                     "content" => "out1",
                     "is_error" => false
                   },
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_2",
                     "content" => "boom",
                     "is_error" => true
                   }
                 ]
               }
             ]
    end

    test "translates tool_choice to the Anthropic shape and falls back to :auto for :required" do
      for {choice, expected} <- [
            {:auto, %{"type" => "auto"}},
            {:none, %{"type" => "none"}},
            {:required, %{"type" => "auto"}},
            {{:tool, "shell_cmd"}, %{"type" => "tool", "name" => "shell_cmd"}}
          ] do
        payload = AnthropicClient.format_request_payload(%RunRequest{tool_choice: choice}, [])
        assert payload["tool_choice"] == expected
      end
    end

    test "passes through temperature and top_p when set" do
      payload =
        AnthropicClient.format_request_payload(
          %RunRequest{temperature: 0.3, top_p: 0.9},
          []
        )

      assert payload["temperature"] == 0.3
      assert payload["top_p"] == 0.9
    end

    test "uses request max_tokens when provided" do
      payload = AnthropicClient.format_request_payload(%RunRequest{max_tokens: 1024}, [])
      assert payload["max_tokens"] == 1024
    end
  end

  describe "normalize_endpoint/2" do
    test "appends endpoint to clean base URL" do
      assert AnthropicClient.normalize_endpoint("https://api.anthropic.com/v1", "/v1/messages") ==
               "https://api.anthropic.com/v1/messages"
    end

    test "strips trailing slash before appending" do
      assert AnthropicClient.normalize_endpoint("https://api.anthropic.com/v1/", "/v1/messages") ==
               "https://api.anthropic.com/v1/messages"
    end

    test "strips duplicate endpoint before appending" do
      assert AnthropicClient.normalize_endpoint(
               "https://api.anthropic.com/v1/messages",
               "/v1/messages"
             ) == "https://api.anthropic.com/v1/messages"
    end

    test "strips duplicate endpoint with trailing slash" do
      assert AnthropicClient.normalize_endpoint(
               "https://api.anthropic.com/v1/messages/",
               "/v1/messages"
             ) == "https://api.anthropic.com/v1/messages"
    end
  end
end
