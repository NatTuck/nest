defmodule Mix.Tasks.Nest.CompactAgentTest do
  @moduledoc """
  Unit tests for the `mix nest.compact_agent` argument parsing.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Nest.CompactAgent

  test "parses a {space}/{name} target and the flags" do
    assert {:ok, {"visual-possum", "root"}, []} =
             CompactAgent.parse_args(["visual-possum/root"])

    assert {:ok, {"a", "b"}, opts} =
             CompactAgent.parse_args([
               "a/b",
               "--apply",
               "--force",
               "--model",
               "deepseek/deepseek-flash",
               "--focus",
               "keep the API decisions",
               "--max-calls",
               "3"
             ])

    assert opts[:apply] == true
    assert opts[:force] == true
    assert opts[:model] == "deepseek/deepseek-flash"
    assert opts[:focus] == "keep the API decisions"
    assert opts[:max_calls] == 3
  end

  test "rejects a missing/short/extra target" do
    assert {:error, message} = CompactAgent.parse_args([])
    assert message =~ "target"

    assert {:error, _message} = CompactAgent.parse_args(["no-slash"])
    assert {:error, _message} = CompactAgent.parse_args(["a/b", "c/d"])
  end

  test "rejects unknown options" do
    assert {:error, message} = CompactAgent.parse_args(["a/b", "--wat"])
    assert message =~ "--wat"
  end
end
