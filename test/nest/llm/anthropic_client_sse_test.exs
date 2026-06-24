defmodule Nest.LLM.AnthropicClientSSETest do
  use ExUnit.Case, async: true

  import Mimic

  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.RunResponse

  setup :verify_on_exit!

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

    test "captures cache_read and cache_creation tokens from message_start" do
      sse = """
      event: message_start
      data: {"message":{"id":"msg_7","model":"claude-3-opus-20240229","usage":{"input_tokens":100,"cache_read_input_tokens":3200,"cache_creation_input_tokens":0,"output_tokens":1}}}

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

      assert usage.input_tokens == 100
      assert usage.cache_read_input_tokens == 3200
      assert usage.cache_creation_input_tokens == 0
      assert usage.output_tokens == 7
    end

    test "message_delta overrides cache values when present (final values win)" do
      # The final `message_delta.usage` block is the authoritative
      # source for cache totals. It should override whatever
      # `message_start` reported.
      sse = """
      event: message_start
      data: {"message":{"id":"msg_8","model":"claude-3-opus-20240229","usage":{"input_tokens":100,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0,"output_tokens":1}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7,"cache_read_input_tokens":3500,"cache_creation_input_tokens":50}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      events = run_with_sse(sse)
      {:done, %{response: %RunResponse{usage: usage}}} = List.last(events)

      # The `message_delta` values (final) win.
      assert usage.cache_read_input_tokens == 3500
      assert usage.cache_creation_input_tokens == 50
    end

    test "cache fields default to 0 when absent from both events" do
      # Backward-compat: providers that don't support prompt
      # caching don't include the cache fields in the usage
      # block. They should be reported as 0, not crash.
      sse = """
      event: message_start
      data: {"message":{"id":"msg_9","model":"claude-3-opus-20240229","usage":{"input_tokens":50,"output_tokens":1}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      events = run_with_sse(sse)
      {:done, %{response: %RunResponse{usage: usage}}} = List.last(events)

      assert usage.input_tokens == 50
      assert usage.cache_read_input_tokens == 0
      assert usage.cache_creation_input_tokens == 0
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
