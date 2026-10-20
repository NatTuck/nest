defmodule Nest.ToolsEditTest do
  @moduledoc """
  Tests for the `edit` tool (`Nest.Tools.FileTools.edit_function/1` and its
  private `edit/3`).

  The `edit` tool performs an exact string replacement in a file
  (Claude Code's Edit semantics). `old_text` must match uniquely
  unless `replace_all: true`. The file is left unchanged on any
  error (not-found, ambiguous match, file-missing).

  Split out from `test/nest/tools_test.exs` to keep that file
  under the 500-line Credo cap.
  """
  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.LLM.Tool, as: Function
  alias Nest.Sandbox.Mounts
  alias Nest.Tools

  describe "get_function/2" do
    test "returns the edit function", %{tmp: dir} do
      function = Tools.get_function("file-edit", Mounts.new(dir, nil))

      assert %Function{} = function
      assert function.name == "file-edit"
      assert function.description =~ "string replacement"
    end
  end

  describe "schema" do
    test "edit's schema requires path, old_text, new_text and defaults replace_all to false",
         %{tmp: dir} do
      schema = Tools.get_function("file-edit", Mounts.new(dir, nil)).parameters_schema

      assert schema["required"] == ["path", "old_text", "new_text"]
      assert schema["properties"]["replace_all"]["default"] == false
    end
  end

  describe "edit behavior" do
    test "replaces the unique occurrence with replace_all: false", %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "hello world\nbye world\n")

      function = Tools.get_function("file-edit", Mounts.new(dir, nil))

      assert {:ok, msg} =
               invoke(function, %{
                 "path" => "foo.txt",
                 "old_text" => "hello world",
                 "new_text" => "hi world"
               })

      assert msg =~ "Replaced 1 occurrence"
      assert File.read!(path) == "hi world\nbye world\n"
    end

    test "returns error when old_text is not found; file is unchanged", %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "hello world\n")

      function = Tools.get_function("file-edit", Mounts.new(dir, nil))

      assert {:error, msg} =
               invoke(function, %{"path" => "foo.txt", "old_text" => "missing", "new_text" => "x"})

      assert msg =~ "not found"
      assert File.read!(path) == "hello world\n"
    end

    test "returns error when old_text matches multiple times and replace_all is false; file is unchanged",
         %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "foo\nfoo\nfoo\n")

      function = Tools.get_function("file-edit", Mounts.new(dir, nil))

      assert {:error, msg} =
               invoke(function, %{"path" => "foo.txt", "old_text" => "foo", "new_text" => "bar"})

      assert msg =~ "matches 3 locations"
      assert msg =~ "replace_all: true"
      assert File.read!(path) == "foo\nfoo\nfoo\n"
    end

    test "replaces all occurrences with replace_all: true", %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "foo\nfoo\nfoo\n")

      function = Tools.get_function("file-edit", Mounts.new(dir, nil))

      assert {:ok, msg} =
               invoke(function, %{
                 "path" => "foo.txt",
                 "old_text" => "foo",
                 "new_text" => "bar",
                 "replace_all" => true
               })

      assert msg =~ "Replaced 3 occurrence"
      assert File.read!(path) == "bar\nbar\nbar\n"
    end

    test "returns error when old_text is an empty string", %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "hello\n")

      function = Tools.get_function("file-edit", Mounts.new(dir, nil))

      assert {:error, msg} =
               invoke(function, %{"path" => "foo.txt", "old_text" => "", "new_text" => "x"})

      assert msg =~ "non-empty"
    end

    test "returns error when the file does not exist", %{tmp: dir} do
      function = Tools.get_function("file-edit", Mounts.new(dir, nil))

      # The read is the sandbox's read-only host fast-path (no bwrap),
      # so a missing file surfaces as a clean "File not found".
      assert {:error, msg} =
               invoke(function, %{
                 "path" => "missing.txt",
                 "old_text" => "foo",
                 "new_text" => "bar"
               })

      assert msg =~ "missing.txt"
    end
  end

  setup do
    # A workspace outside /tmp (the scratch dir is bound at /tmp, so a
    # /tmp-rooted workspace is rejected). Unique per test so parallel tests
    # don't collide on the same file path.
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_edit_test_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> rm_tmp!(dir, "nest_edit_test_") end)
    %{tmp: dir}
  end

  # Helper to invoke a tool's function with the given args, using
  # permissive sandbox caps that allow the test's workspace for both
  # read and write. Tools get `caps` from their `context` arg.
  defp invoke(%Function{function: fun}, args) do
    fun.(args, %{
      caps: %{
        "fs" => %{
          "read" => ["/"],
          "write" => ["/", ":workspace"]
        },
        "net" => true
      }
    })
  end
end
