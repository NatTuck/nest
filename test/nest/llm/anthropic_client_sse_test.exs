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

      assert usage.cache_read_input_tokens == 0
      assert usage.cache_creation_input_tokens == 0
    end
  end

  describe "chunk boundary handling" do
    test "named events survive being split at every byte offset" do
      sse = """
      event: message_start
      data: {"message":{"id":"msg_split","model":"x","usage":{"input_tokens":1,"output_tokens":1}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"shell-cmd","input":{}}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":"}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"ls -la\\"}"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

      event: message_stop
      data: {"type":"message_stop"}

      """

      expected = run_with_chunks([sse])

      assert {:tool_call_start, %{id: "toolu_1", name: "shell-cmd", index: 0}} in expected

      assert {:tool_call_delta, %{id: :by_index, index: 0, arguments_delta: "{\"command\":"}} in expected

      assert {:tool_call_delta, %{id: :by_index, index: 0, arguments_delta: "\"ls -la\"}"}} in expected

      size = byte_size(sse)

      for split <- 0..size do
        left = binary_part(sse, 0, split)
        right = binary_part(sse, split, size - split)

        assert run_with_chunks([left, right]) == expected,
               "canonical events changed when the stream was split at byte #{split}"
      end

      byte_by_byte = for <<byte <- sse>>, do: <<byte>>
      assert run_with_chunks(byte_by_byte) == expected
    end
  end

  describe "error handling" do
    test "parses synthetic error chunks, tagging a nil status as :transport" do
      http_error =
        "event: error\ndata: " <>
          Jason.encode!(%{error: "http_error", status: 429, body: "rate limited"}) <> "\n\n"

      transport_error =
        "event: error\ndata: " <>
          Jason.encode!(%{error: "request_failed", status: nil, body: "connection refused"}) <>
          "\n\n"

      assert [{:error, {"http_error", 429, "rate limited"}}] = run_with_sse(http_error)

      assert [{:error, {"request_failed", :transport, "connection refused"}}] =
               run_with_sse(transport_error)
    end
  end

  describe "stream completeness" do
    test "content with no message_stop or stop_reason is :stream_incomplete" do
      sse = """
      event: message_start
      data: {"message":{"id":"msg_3","model":"claude-3-opus-20240229","usage":{"input_tokens":1,"output_tokens":1}}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

      """

      events = run_with_sse(sse)

      assert {:text, "Hello"} in events
      assert {:error, {:stream_incomplete, :no_terminator}} in events
      refute Enum.any?(events, &match?({:done, _}, &1))
    end

    test "a stop_reason is enough to complete even without message_stop" do
      sse = """
      event: message_start
      data: {"message":{"id":"msg_4","model":"claude-3-opus-20240229","usage":{"input_tokens":1,"output_tokens":1}}}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

      """

      events = run_with_sse(sse)

      assert {:done, %{response: %RunResponse{stop_reason: "end_turn"}}} = List.last(events)
    end
  end

  describe "idle watchdog" do
    test "before the first chunk it fires at the first-byte bound" do
      worker =
        spawn_link(fn ->
          receive do
            :never -> :ok
          end
        end)

      ref = Process.monitor(worker)

      events =
        AnthropicClient.consume_sse_from_mailbox(
          worker: worker,
          first_byte_timeout: 50,
          stream_idle_timeout: 5_000
        )
        |> Enum.to_list()

      # Nothing has been streamed yet, so the prefill bound applies: the provider
      # is allowed to be silent for the whole first-byte window.
      assert events == [{:error, {:stream_idle_timeout, {:first_byte, 50}}}]
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    end

    test "a stall after the first chunk fires at the idle bound, not the first-byte bound" do
      worker =
        spawn_link(fn ->
          receive do
            :never -> :ok
          end
        end)

      ref = Process.monitor(worker)
      parent = self()

      # One chunk, then silence. The first-byte bound is the *looser* of the two,
      # so an implementation that kept using it would not fire inside this test's
      # timeout — and the tuple would name the wrong bound anyway.
      spawn_link(fn ->
        send(parent, {:req_chunk, "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"})
      end)

      events =
        AnthropicClient.consume_sse_from_mailbox(
          worker: worker,
          first_byte_timeout: 1_000,
          stream_idle_timeout: 50
        )
        |> Enum.to_list()

      assert events == [{:error, {:stream_idle_timeout, {:stream_idle, 50}}}]
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    end

    test "silence longer than the idle bound before the first chunk still succeeds" do
      # The prefill case: a cache-miss prefill is silence *before* the first
      # chunk, and the idle bound must not be measuring it. The chunk arrives at
      # 100ms — 2.5x the idle bound and far inside the first-byte bound — so an
      # implementation that armed the idle bound first always fails this.
      parent = self()

      spawn_link(fn ->
        Process.send_after(
          parent,
          {:req_chunk,
           ~s(event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n)},
          100
        )

        Process.send_after(parent, :req_done, 100)
      end)

      events =
        AnthropicClient.consume_sse_from_mailbox(
          first_byte_timeout: 2_000,
          stream_idle_timeout: 40
        )
        |> Enum.to_list()

      assert {:done, _} = List.last(events)
      refute Enum.any?(events, &match?({:error, _}, &1))
    end
  end

  # Drive `consume_sse_from_mailbox/0` by sending `{:req_chunk, _}`
  # and `:req_done` messages to the test process from a helper, then
  # collecting the canonical events the stream produces.
  defp run_with_sse(sse), do: run_with_chunks([sse])

  defp run_with_chunks(chunks) do
    parent = self()

    # The helper sends chunks then signals done. The consumer's
    # Stream.resource runs in `parent` (the test process) and
    # receives these messages from its own mailbox.
    spawn_link(fn ->
      Enum.each(chunks, &send(parent, {:req_chunk, &1}))
      send(parent, :req_done)
    end)

    AnthropicClient.consume_sse_from_mailbox() |> Enum.to_list()
  end
end
