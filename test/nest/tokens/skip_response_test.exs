defmodule Nest.Tokens.SkipResponseTest do
  @moduledoc """
  Tests for `Nest.Tokens.SkipResponse`.

  Covers:
  - Standard rendering with tool name and budget
  - Edge cases: missing/invalid tool name
  - Format includes actionable guidance for the LLM
  """

  use ExUnit.Case, async: true

  alias Nest.Tokens.SkipResponse

  describe "render/2" do
    test "includes tool name and remaining budget" do
      result = SkipResponse.render("shell_cmd", 100)
      assert result =~ "[skipped:"
      assert result =~ "shell_cmd"
      assert result =~ "~100 tokens"
    end

    test "includes reformulation guidance" do
      result = SkipResponse.render("read_file", 50)
      assert result =~ "Reformulate"
      assert result =~ "filter" or result =~ "specific"
    end

    test "falls back to a simpler message on bad inputs" do
      # Non-string tool name
      result = SkipResponse.render(nil, 100)
      assert result == ""
    end

    test "handles zero budget" do
      result = SkipResponse.render("shell_cmd", 0)
      assert result =~ "shell_cmd"
      assert result =~ "~0 tokens"
    end

    test "handles large budget" do
      result = SkipResponse.render("read_file", 999_999)
      assert result =~ "~999999 tokens"
    end
  end
end
