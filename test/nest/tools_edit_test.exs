defmodule Nest.ToolsEditTest do
  @moduledoc """
  Tests for the `edit` tool (`Nest.Tools.edit_function/2` and
  `Nest.Tools.edit/4`).

  The `edit` tool performs an exact string replacement in a file
  (Claude Code's Edit semantics). `old_text` must match uniquely
  unless `replace_all: true`. The file is left unchanged on any
  error (not-found, ambiguous match, file-missing).

  Split out from `test/nest/tools_test.exs` to keep that file
  under the 500-line Credo cap.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.LLM.Tool, as: Function
  alias Nest.Tools

  describe "get_function/2" do
    test "returns the edit function", %{tmp: dir} do
      function = Tools.get_function("file-edit", dir)

      assert %Function{} = function
      assert function.name == "file-edit"
      assert function.description =~ "string replacement"
    end

    test "edit struct does not carry a per-tool max_result_tokens field; cap is enforced by BatchSizer",
         %{tmp: dir} do
      function = Tools.get_function("file-edit", dir)
      refute Map.has_key?(function, :max_result_tokens)
    end
  end

  describe "schema" do
    test "edit's schema requires path, old_text, new_text", %{tmp: dir} do
      schema = Tools.get_function("file-edit", dir).parameters_schema
      assert schema["required"] == ["path", "old_text", "new_text"]
    end

    test "edit's schema documents path, old_text, new_text, replace_all, max_result_tokens",
         %{tmp: dir} do
      properties = Tools.get_function("file-edit", dir).parameters_schema["properties"]

      assert Map.has_key?(properties, "path")
      assert Map.has_key?(properties, "old_text")
      assert Map.has_key?(properties, "new_text")
      assert Map.has_key?(properties, "replace_all")
      assert Map.has_key?(properties, "max_result_tokens")
    end

    test "edit's replace_all defaults to false", %{tmp: dir} do
      property =
        Tools.get_function("file-edit", dir).parameters_schema["properties"]["replace_all"]

      assert property["default"] == false
    end

    test "edit's max_result_tokens is optional (not in required)", %{tmp: dir} do
      required = Tools.get_function("file-edit", dir).parameters_schema["required"]
      refute "max_result_tokens" in required
    end
  end

  describe "edit behavior" do
    test "replaces the unique occurrence with replace_all: false", %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "hello world\nbye world\n")

      function = Tools.get_function("file-edit", dir)

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

      function = Tools.get_function("file-edit", dir)

      assert {:error, msg} =
               invoke(function, %{"path" => "foo.txt", "old_text" => "missing", "new_text" => "x"})

      assert msg =~ "not found"
      assert File.read!(path) == "hello world\n"
    end

    test "returns error when old_text matches multiple times and replace_all is false; file is unchanged",
         %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "foo\nfoo\nfoo\n")

      function = Tools.get_function("file-edit", dir)

      assert {:error, msg} =
               invoke(function, %{"path" => "foo.txt", "old_text" => "foo", "new_text" => "bar"})

      assert msg =~ "matches 3 locations"
      assert msg =~ "replace_all: true"
      assert File.read!(path) == "foo\nfoo\nfoo\n"
    end

    test "replaces all occurrences with replace_all: true", %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "foo\nfoo\nfoo\n")

      function = Tools.get_function("file-edit", dir)

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

      function = Tools.get_function("file-edit", dir)

      assert {:error, msg} =
               invoke(function, %{"path" => "foo.txt", "old_text" => "", "new_text" => "x"})

      assert msg =~ "non-empty"
    end

    test "returns error when the file does not exist", %{tmp: dir} do
      function = Tools.get_function("file-edit", dir)

      log =
        capture_log(fn ->
          assert {:error, msg} =
                   invoke(function, %{
                     "path" => "missing.txt",
                     "old_text" => "foo",
                     "new_text" => "bar"
                   })

          assert msg =~ "missing.txt" or msg =~ "No such file"
        end)

      # bwrap's non-zero exit on the missing-file path is a
      # deliberate diagnostic — assert on it so the test's
      # intent is self-documenting and the log doesn't escape.
      assert log =~ "ShellCmd.execute: bwrap exited non-zero"
      assert log =~ "missing.txt"
    end

    test "edit preserves surrounding content (not the whole file)", %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "header\ntarget line\nfooter\n")

      function = Tools.get_function("file-edit", dir)

      assert {:ok, _} =
               invoke(function, %{
                 "path" => "foo.txt",
                 "old_text" => "target line",
                 "new_text" => "edited line"
               })

      assert File.read!(path) == "header\nedited line\nfooter\n"
    end
  end

  describe "edit tool in get_functions/2" do
    test "edit is included when added to a tool list", %{tmp: dir} do
      functions = Tools.get_functions(["file-edit"], dir)
      assert length(functions) == 1
      assert hd(functions).name == "file-edit"
    end

    test "edit is filtered out when not in the tool list", %{tmp: dir} do
      functions = Tools.get_functions(["file-read"], dir)
      names = Enum.map(functions, & &1.name)
      refute "file-edit" in names
    end
  end

  setup do
    # Use a unique tmp directory per test so parallel tests don't
    # collide on the same file path. The %{} returns the context
    # map (with `tmp:` key) injected into each test.
    dir = Path.join(System.tmp_dir!(), "nest_edit_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp: dir}
  end

  # Helper to invoke a tool's function with the given args, using
  # permissive sandbox caps that allow the test's tmp dir for both
  # read and write. Tools get `caps` from their `context` arg.
  defp invoke(%Function{function: fun}, args) do
    fun.(args, %{
      caps: %{
        "fs" => %{
          "read" => ["/tmp", "/", ":workspace"],
          "write" => ["/tmp", "/", ":workspace"]
        },
        "net" => true
      }
    })
  end
end
