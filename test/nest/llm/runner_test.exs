defmodule Nest.LLM.RunnerTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.Runner

  describe "format_error/1" do
    test "renders an integer-status http_error with a body on its own line" do
      assert Runner.format_error({"http_error", 429, "rate limited"}) ==
               "Error: HTTP 429: http_error\nrate limited"
    end

    test "renders an integer-status http_error with empty body as a single line" do
      assert Runner.format_error({"http_error", 500, ""}) ==
               "Error: HTTP 500: http_error"
    end

    test "renders a transport failure (status :transport) with the body as the cause" do
      # Regression for the typhon `request_failed` case: the SSE
      # chunk used to surface as the bare literal `"request_failed"`
      # because `error_event_from_map/1` discarded the body. The
      # canonical event now carries the body, and `format_error/1`
      # renders it so the user sees the real failure reason.
      assert Runner.format_error(
               {"request_failed", :transport,
                "%Finch.TransportError{reason: :econnrefused, source: %Mint.TransportError{reason: :econnrefused}}"}
             ) ==
               "Error: request_failed\n%Finch.TransportError{reason: :econnrefused, source: %Mint.TransportError{reason: :econnrefused}}"
    end

    test "renders a transport failure with a nil/empty body as a single line" do
      assert Runner.format_error({"request_failed", :transport, nil}) ==
               "Error: request_failed"

      assert Runner.format_error({"request_failed", :transport, ""}) ==
               "Error: request_failed"
    end

    test "truncates a very long transport-level body" do
      long_body = String.duplicate("a", 800)

      message = Runner.format_error({"request_failed", :transport, long_body})

      assert String.starts_with?(message, "Error: request_failed\n")
      assert String.length(message) < String.length(long_body) + 100
      assert String.contains?(message, "...(truncated)")
    end

    test "falls back to inspect for unrecognized error shapes" do
      assert Runner.format_error(:something_else) ==
               "Error: :something_else"
    end
  end

  describe "consume/2 forwards tool-call hooks" do
    # Regression: `Runner.build_stream_consumer/1` used to drop
    # `on_tool_call_start` / `on_tool_call_delta` from the
    # `StreamConsumer` struct, so the HTTP worker's hooks that
    # forward `:delta_received` to the Agent mailbox were
    # silently inert. Without the forwarding, the JS never
    # saw `chat:delta` events with `partType: "tool_use_*"`
    # and tool calls only appeared once the assistant message
    # finalized.
    test "invokes on_tool_call_start and on_tool_call_delta for each event" do
      test_pid = self()

      events = [
        {:tool_call_start, %{id: "call_abc", name: "shell-cmd", index: 0}},
        {:tool_call_delta, %{id: "call_abc", index: 0, arguments_delta: "{\"command\":"}},
        {:tool_call_delta, %{id: "call_abc", index: 0, arguments_delta: "\"ls\"}"}},
        {:finish_reason, "tool_calls"},
        {:done, nil}
      ]

      callbacks = %{
        on_tool_call_start: fn event, sent ->
          send(test_pid, {:tool_call_start_fwd, event})
          sent
        end,
        on_tool_call_delta: fn event, sent ->
          send(test_pid, {:tool_call_delta_fwd, event})
          sent
        end,
        should_stop: fn _ -> false end
      }

      assert {:ok, _} = Runner.consume(events, callbacks)

      assert_received {:tool_call_start_fwd, %{id: "call_abc", name: "shell-cmd"}}
      assert_received {:tool_call_delta_fwd, %{arguments_delta: "{\"command\":"}}
      assert_received {:tool_call_delta_fwd, %{arguments_delta: "\"ls\"}"}}
    end

    test "compactor-style consumer (no tool hooks) still works" do
      # When the callbacks map omits tool-call hooks, the
      # consumer's default `nil` path takes over — no forward,
      # no crash. The compactor uses this shape.
      events = [
        {:tool_call_start, %{id: "call_x", name: "noop"}},
        {:finish_reason, "stop"},
        {:done, nil}
      ]

      callbacks = %{
        on_text: fn _text, sent -> sent end,
        on_thinking: fn _text, sent -> sent end,
        should_stop: fn _ -> false end
      }

      assert {:ok, _} = Runner.consume(events, callbacks)
    end
  end
end
