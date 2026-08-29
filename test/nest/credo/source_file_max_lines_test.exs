defmodule Nest.Credo.Check.SourceFileMaxLinesTest do
  use ExUnit.Case, async: true

  # The check lives in `test/support/credo/`, which is excluded from the
  # normal test compilation (it's loaded by Credo's `requires`). Load it
  # here so we can exercise its pure `count/1`.
  Code.require_file("../../support/credo/source_file_max_lines.ex", __DIR__)

  alias Nest.Credo.Check.SourceFileMaxLines

  defp count(content), do: SourceFileMaxLines.count(String.split(content, "\n"))

  describe "code line counting" do
    test "excludes blanks and full-line comments" do
      content = """
      defmodule A do

        # a comment

        def run do
          :ok
        end
      end
      """

      # code lines: defmodule, def run, :ok, end, end = 5
      assert count(content).code == 5
    end

    test "excludes doc annotations and their heredoc bodies" do
      content = """
      defmodule A do
        @doc \"\"\"
        Long documentation text.
        Even more doc text.
        \"\"\"
        @moduledoc false
        def run, do: :ok
      end
      """

      # code lines: defmodule, def run, end = 3
      assert count(content).code == 3
    end

    test "counts regular heredocs (multi-line strings)" do
      content = """
      defmodule A do
        prompt = \"\"\"
        line one
        line two
        \"\"\"
        def run, do: prompt
      end
      """

      # code lines: defmodule, `prompt = """`, line one, line two, `"""`,
      # def run, end = 7 (heredoc body counts)
      assert count(content).code == 7
    end

    test "counts lines with trailing comments" do
      content = """
      defmodule A do
        x = 1 # a trailing comment
      end
      """

      # code lines: defmodule, `x = 1 # ...`, end = 3
      assert count(content).code == 3
    end

    test "excludes single-line doc annotations but counts type specs" do
      content = """
      defmodule A do
        @doc "a one-line doc"
        @spec run() :: :ok
        def run, do: :ok
      end
      """

      # code lines: defmodule, @spec, def run, end = 4
      assert count(content).code == 4
    end

    test "counts multiline sigils as multi-line strings" do
      content = """
      defmodule A do
        pattern = ~r\"\"\"
        a
        b
        \"\"\"
        def run, do: pattern
      end
      """

      # code lines: defmodule, `pattern = ~r\"\"\"`, a, b, `\"\"\"`,
      # def run, end = 7
      assert count(content).code == 7
    end
  end

  describe "total line counting" do
    test "counts every line including blanks and comments" do
      content = """
      defmodule A do

        # comment
      end
      """

      assert count(content).total == 4
    end
  end
end
