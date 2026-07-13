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
end
