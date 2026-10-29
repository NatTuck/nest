defmodule Nest.LLM.ClientTest do
  use ExUnit.Case, async: true

  alias Nest.DotConfig
  alias Nest.LLM.Client
  alias Nest.LLM.OpenAIClient

  describe "accumulate/2 with tool_call_delta id: :by_index" do
    test "ignores a by_index delta when no matching :tool_call_start has been seen" do
      acc =
        Client.new_accumulator()
        |> Client.accumulate(
          {:tool_call_delta, %{id: :by_index, index: 7, arguments_delta: "stray"}}
        )

      assert acc.tool_calls == %{}
    end
  end

  describe "vLLM tool_call sequence end-to-end (typhon provider)" do
    # End-to-end regression for the typhon provider (vLLM
    # backend). vLLM emits a tool_call seed frame WITHOUT a
    # `function.arguments` field — only `{id, type, index,
    # function.name}`. The follow-up argument deltas carry only
    # `{index, function.arguments}` and arrive as
    # `{:tool_call_delta, %{id: :by_index, ...}}`. If the parser
    # drops the seed, every by_index delta is silently dropped
    # and `finalize/2` returns `tool_calls: []` despite the
    # model emitting a tool call. Drives the parser through
    # `consume_sse_from_mailbox/0` and then through the
    # accumulator — mirrors what the agent sees in production.

    test "full vLLM SSE sequence produces a populated tool call on the final RunResponse" do
      seed_frame = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "id" => "chatcmpl-tool-v1",
                  "type" => "function",
                  "index" => 0,
                  "function" => %{"name" => "get_weather"}
                }
              ]
            }
          }
        ]
      }

      arg_delta = fn frag ->
        %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{"index" => 0, "function" => %{"arguments" => frag}}
                ]
              }
            }
          ]
        }
      end

      finish_frame = %{
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]
      }

      chunks =
        Enum.map(
          [
            seed_frame,
            arg_delta.("{\"location\": \""),
            arg_delta.("San"),
            arg_delta.(" Francisco"),
            arg_delta.("\"}")
          ] ++ [finish_frame],
          fn frame -> "data: " <> Jason.encode!(frame) <> "\n\n" end
        )

      events = run_with_chunks(chunks)

      arg_deltas =
        events
        |> Enum.filter(&match?({:tool_call_delta, %{id: :by_index}}, &1))
        |> Enum.map(fn {:tool_call_delta, %{arguments_delta: d}} -> d end)

      assert arg_deltas == ["{\"location\": \"", "San", " Francisco", "\"}"]

      response =
        events
        |> Enum.reduce(Client.new_accumulator(), fn event, acc ->
          Client.accumulate(acc, event)
        end)
        |> Client.finalize()

      assert [%Nest.Messages.ToolCall{} = call] = response.tool_calls
      assert call.id == "chatcmpl-tool-v1"
      assert call.name == "get_weather"
      assert call.arguments == %{"location" => "San Francisco"}
      assert response.stop_reason == "tool_calls"
    end
  end

  describe "tool-call arguments" do
    test "a buffer that does not decode is answered with none, and says so" do
      # A `context-compact` call whose arguments JSON is truncated stages a
      # compaction with no `preserve`, which is the loss that contract exists to
      # prevent, so the decoder says so rather than answering silently.
      acc = %{
        Client.new_accumulator()
        | tool_calls: %{
            "call_1" => %{
              id: "call_1",
              name: "context-compact",
              arguments_buffer: ["{not json"]
            }
          }
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [%Nest.Messages.ToolCall{name: "context-compact", arguments: args}] =
                   Client.finalize(acc).tool_calls

          assert args == %{}
        end)

      assert log =~ "tool-call arguments did not decode"
    end

    test "an empty buffer is answered with none" do
      # The benign case: a call that genuinely carried no arguments, which every
      # tool with only optional arguments can produce. That it logs nothing is
      # not assertable — `capture_log` collects every process's logs, so an
      # absence assertion there can be tripped by any concurrent test and would
      # test nothing. A stray warning would show up as test output instead.
      empty = %{
        Client.new_accumulator()
        | tool_calls: %{
            "call_2" => %{id: "call_2", name: "context-compact", arguments_buffer: []}
          }
      }

      assert [%Nest.Messages.ToolCall{arguments: args}] = Client.finalize(empty).tool_calls
      assert args == %{}
    end
  end

  describe "credential headers" do
    # These are the exact shapes the two clients put on the wire. They are
    # asserted here rather than through `run/2` because each client issues
    # its request from a `spawn_link`ed worker process, which a per-test
    # Mimic stub cannot reach (Mimic's private mode is process-scoped).
    test "a nil or empty key means no credential at all" do
      # `nil` fails the `is_binary` guard and `""` fails the `!= ""` guard, so
      # both are asserted: they are different conditions, not one path.
      assert Client.bearer_auth_opts(nil) == []
      assert Client.bearer_auth_opts("") == []
      assert Client.api_key_header(nil) == []
      assert Client.api_key_header("") == []
    end

    test "a resolved key means the provider's own credential" do
      assert Client.bearer_auth_opts("sk-abc") == [auth: {:bearer, "sk-abc"}]
      assert Client.api_key_header("sk-abc") == [{"x-api-key", "sk-abc"}]
    end
  end

  describe "the two silence bounds" do
    test "both fall back to a finite default when the provider leaves them unset" do
      # `ClientConfig` fields default to nil, which used to become `:infinity` —
      # unbounded socket read *and* unbounded SSE watchdog, so a silently dropped
      # connection hung the turn forever and no retry could fire. A missing key
      # is the same `nil` clause.
      assert Client.first_byte_timeout(first_byte_timeout: nil) ==
               Client.default_first_byte_timeout_ms()

      assert Client.stream_idle_timeout(stream_idle_timeout: nil) ==
               Client.default_stream_idle_timeout_ms()

      # The defaults are the config module's, in milliseconds: a long prefill
      # window and a much tighter post-first-chunk one.
      assert Client.default_first_byte_timeout_ms() ==
               DotConfig.default_first_byte_timeout_seconds() * 1_000

      assert Client.default_stream_idle_timeout_ms() ==
               DotConfig.default_stream_idle_timeout_seconds() * 1_000

      assert Client.default_first_byte_timeout_ms() > Client.default_stream_idle_timeout_ms()
    end

    test "an explicit value wins, including :infinity to opt out" do
      assert Client.first_byte_timeout(first_byte_timeout: :infinity) == :infinity
      assert Client.stream_idle_timeout(stream_idle_timeout: 42) == 42
      assert Client.first_byte_timeout(first_byte_timeout: 42) == 42
      assert Client.stream_idle_timeout(stream_idle_timeout: :infinity) == :infinity
    end
  end

  defp run_with_chunks(chunks) do
    parent = self()

    spawn_link(fn ->
      Enum.each(chunks, fn chunk -> send(parent, {:req_chunk, chunk}) end)
      send(parent, :req_done)
    end)

    stream = OpenAIClient.consume_sse_from_mailbox()
    Enum.to_list(stream)
  end
end
