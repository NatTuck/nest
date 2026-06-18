defmodule Nest.LLM.ClientTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.Client

  describe "accumulate/2 with tool_call_delta id: :by_index" do
    test "resolves the by_index id to the real id captured by the matching :tool_call_start" do
      acc =
        Client.new_accumulator()
        |> Client.accumulate({:tool_call_start, %{id: "toolu_1", name: "shell_cmd", index: 0}})
        |> Client.accumulate(
          {:tool_call_delta, %{id: :by_index, index: 0, arguments_delta: "{\"command\":\"ls\"}"}}
        )

      assert acc.tool_calls["toolu_1"].arguments_buffer == "{\"command\":\"ls\"}"
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
end
