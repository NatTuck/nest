defmodule Nest.LLM.OpenAIClientTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.OpenAIClient
  alias Nest.LLM.RunRequest
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
    test "parses synthetic http_error chunk into {:error, _} event" do
      error_chunk =
        "data: " <>
          Jason.encode!(%{error: "http_error", status: 429, body: "rate limited"}) <> "\n\n"

      events = run_with_chunk(error_chunk)

      assert {:error, "http_error"} in events
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
