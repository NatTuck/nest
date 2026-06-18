defmodule Nest.LLM.AnthropicClientTest do
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
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

  describe "consume_sse_from_mailbox/0 (SSE translation)" do
    test "translates message_start, content_block_*, message_delta, message_stop into canonical events" do
      sse = """
      event: message_start
      data: {"message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-3-opus-20240229","content":[],"stop_reason":null,"usage":{"input_tokens":42,"output_tokens":1}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      events = run_with_sse(sse)

      assert {:text, "Hello "} in events
      assert {:text, "world"} in events
      assert {:finish_reason, "end_turn"} in events
      assert {:done, %{response: %RunResponse{stop_reason: "end_turn"}}} = List.last(events)
    end

    test "captures thinking_signature from content_block_start.signature and emits :thinking_signature" do
      sse = """
      event: message_start
      data: {"message":{"id":"msg_2","model":"claude-3-opus-20240229","usage":{"input_tokens":10,"output_tokens":1}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":"sig_xyz"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"let me reason"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      events = run_with_sse(sse)

      assert {:thinking_signature, "sig_xyz"} in events
      assert {:thinking, "let me reason"} in events
    end

    test "captures thinking_signature from a signature_delta event" do
      sse = """
      event: message_start
      data: {"message":{"id":"msg_3","model":"claude-3-opus-20240229","usage":{"input_tokens":5,"output_tokens":1}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_late"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      events = run_with_sse(sse)

      assert {:thinking_signature, "sig_late"} in events
    end

    test "translates tool_use content_block_start into :tool_call_start and input_json_delta into :tool_call_delta" do
      sse = """
      event: message_start
      data: {"message":{"id":"msg_4","model":"claude-3-opus-20240229","usage":{"input_tokens":1,"output_tokens":1}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"shell_cmd","input":{}}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"ls\\"}"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      events = run_with_sse(sse)

      assert {:tool_call_start, %{id: "toolu_1", name: "shell_cmd", index: 0}} in events

      assert {:tool_call_delta, %{id: :by_index, index: 0, arguments_delta: "{\"command\":"}} in events

      assert {:tool_call_delta, %{id: :by_index, index: 0, arguments_delta: "\"ls\"}"}} in events

      assert {:finish_reason, "tool_use"} in events
    end

    test "accumulates input_tokens from message_start and output_tokens from message_delta" do
      sse = """
      event: message_start
      data: {"message":{"id":"msg_5","model":"claude-3-opus-20240229","usage":{"input_tokens":120,"output_tokens":1}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      events = run_with_sse(sse)
      {:done, %{response: %RunResponse{usage: usage}}} = List.last(events)

      assert usage.input_tokens == 120
      assert usage.output_tokens == 7
    end

    test "ignores ping and unknown events" do
      sse = """
      event: ping
      data: {"type":"ping"}

      event: message_start
      data: {"message":{"id":"msg_6","model":"claude-3-opus-20240229","usage":{"input_tokens":1,"output_tokens":1}}}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      events = run_with_sse(sse)

      refute Enum.any?(events, &match?({:ping, _}, &1))
      assert {:finish_reason, "end_turn"} in events
    end
  end

  describe "error handling" do
    test "parses synthetic http_error chunk into {:error, _} event" do
      error_chunk =
        "event: error\ndata: " <>
          Jason.encode!(%{error: "http_error", status: 429, body: "rate limited"}) <> "\n\n"

      events = run_with_sse(error_chunk)

      assert {:error, _} = List.first(events)
    end

    test "parses synthetic request_failed chunk into {:error, _} event" do
      error_chunk =
        "event: error\ndata: " <>
          Jason.encode!(%{error: "request_failed", status: nil, body: "connection refused"}) <>
          "\n\n"

      events = run_with_sse(error_chunk)

      assert {:error, _} = List.first(events)
    end
  end

  # Drive `consume_sse_from_mailbox/0` by sending `{:req_chunk, _}`
  # and `:req_done` messages to the test process from a helper, then
  # collecting the canonical events the stream produces.
  defp run_with_sse(sse) do
    parent = self()

    # The helper sends chunks then signals done. The consumer's
    # Stream.resource runs in `parent` (the test process) and
    # receives these messages from its own mailbox.
    spawn_link(fn ->
      send(parent, {:req_chunk, sse})
      send(parent, :req_done)
    end)

    events = AnthropicClient.consume_sse_from_mailbox() |> Enum.to_list()
    events
  end
end
