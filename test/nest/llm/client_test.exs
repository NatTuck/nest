defmodule Nest.LLM.ClientTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.Client
  alias Nest.LLM.OpenAIClient

  describe "accumulate/2 with tool_call_delta id: :by_index" do
    test "resolves the by_index id to the real id captured by the matching :tool_call_start" do
      acc =
        Client.new_accumulator()
        |> Client.accumulate({:tool_call_start, %{id: "toolu_1", name: "shell-cmd", index: 0}})
        |> Client.accumulate(
          {:tool_call_delta, %{id: :by_index, index: 0, arguments_delta: "{\"command\":\"ls\"}"}}
        )

      assert IO.iodata_to_binary(acc.tool_calls["toolu_1"].arguments_buffer) ==
               "{\"command\":\"ls\"}"

      assert Map.has_key?(acc, :tool_index_map)
      assert acc.tool_index_map[0] == "toolu_1"
    end

    test "ignores a by_index delta when no matching :tool_call_start has been seen" do
      acc =
        Client.new_accumulator()
        |> Client.accumulate(
          {:tool_call_delta, %{id: :by_index, index: 7, arguments_delta: "stray"}}
        )

      assert acc.tool_calls == %{}
    end

    test "a fresh accumulator has no tool_index_map key" do
      refute Map.has_key?(Client.new_accumulator(), :tool_index_map)
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
