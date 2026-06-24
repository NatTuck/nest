defmodule Nest.ToolsInspectFileTest do
  @moduledoc """
  Tests for the `inspect_file` tool.

  The `inspect_file` tool is read-only metadata: it reports a
  file's type, size, line/char/token counts so the LLM can
  decide between `read_file` (full content) and a partial read
  before committing context budget. It never returns file
  content, never modifies the file.

  Split out from `test/nest/tools_test.exs` to keep that file
  under the 500-line Credo cap.
  """
  use ExUnit.Case, async: true

  alias Nest.LLM.Tool, as: Function
  alias Nest.Tools

  describe "get_function/2" do
    test "returns the inspect_file function", %{tmp: dir} do
      function = Tools.get_function("inspect_file", dir)

      assert %Function{} = function
      assert function.name == "inspect_file"
      assert function.description =~ "metadata"
    end

    test "inspect_file has a 256-token default for max_result_tokens", %{tmp: dir} do
      function = Tools.get_function("inspect_file", dir)
      assert function.max_result_tokens == 256
    end
  end

  describe "schema" do
    test "inspect_file's schema requires only path", %{tmp: dir} do
      schema = Tools.get_function("inspect_file", dir).parameters_schema
      assert schema["required"] == ["path"]
    end

    test "inspect_file's schema documents path and max_result_tokens", %{tmp: dir} do
      properties = Tools.get_function("inspect_file", dir).parameters_schema["properties"]

      assert Map.has_key?(properties, "path")
      assert Map.has_key?(properties, "max_result_tokens")
    end

    test "inspect_file's max_result_tokens is optional (not in required)", %{tmp: dir} do
      required = Tools.get_function("inspect_file", dir).parameters_schema["required"]
      refute "max_result_tokens" in required
    end
  end

  describe "inspect_file behavior on text files" do
    test "ASCII text file returns the full stats", %{tmp: dir} do
      # "line one\nline two\nline three\n" = 8+1+8+1+10+1 = 29 bytes.
      # Splitting on "\n" yields 4 elements (the trailing "\n" leaves
      # an empty string), so lines = 4, non-blank = 3.
      path = Path.join(dir, "foo.txt")
      File.write!(path, "line one\nline two\nline three\n")

      function = Tools.get_function("inspect_file", dir)
      assert {:ok, output} = invoke(function, %{"path" => "foo.txt"})

      assert output =~ "File: foo.txt"
      assert output =~ "Type: ASCII text"
      assert output =~ "Size: 29 bytes"
      assert output =~ "Lines: 4"
      assert output =~ "Non-blank lines: 3"
      assert output =~ "Characters: 29"
      assert output =~ "Max line length: 10"
      assert output =~ "Estimated tokens: ~"
    end

    test "UTF-8 text file with multi-byte characters reports char count, not byte count",
         %{tmp: dir} do
      # "héllo\n" is 6 chars but 7 bytes (é = 0xC3 0xA9 in UTF-8
      # plus the newline = 1 byte). Split on "\n" gives 2
      # elements; the empty trailing one is blank.
      path = Path.join(dir, "foo.txt")
      File.write!(path, "héllo\n")

      function = Tools.get_function("inspect_file", dir)
      assert {:ok, output} = invoke(function, %{"path" => "foo.txt"})

      assert output =~ "Type:"
      assert output =~ "UTF-8"
      assert output =~ "Size: 7 bytes"
      assert output =~ "Characters: 6"
      assert output =~ "Lines: 2"
      assert output =~ "Non-blank lines: 1"
      assert output =~ "Max line length: 5"
    end

    test "file with very long lines reports the max line length", %{tmp: dir} do
      path = Path.join(dir, "foo.txt")
      File.write!(path, "short\n" <> String.duplicate("x", 200) <> "\nshort again\n")

      function = Tools.get_function("inspect_file", dir)
      assert {:ok, output} = invoke(function, %{"path" => "foo.txt"})

      assert output =~ "Max line length: 200"
    end

    test "empty file returns the empty-text stats", %{tmp: dir} do
      path = Path.join(dir, "empty.txt")
      File.write!(path, "")

      function = Tools.get_function("inspect_file", dir)
      assert {:ok, output} = invoke(function, %{"path" => "empty.txt"})

      # `file` reports empty files as "empty"; we still treat
      # them as text with zero content.
      assert output =~ "Type: empty"
      assert output =~ "Size: 0 bytes"
      assert output =~ "Characters: 0"
      assert output =~ "Max line length: 0"
      assert output =~ "Non-blank lines: 0"
    end

    test "whitespace-only file reports 0 non-blank lines", %{tmp: dir} do
      path = Path.join(dir, "blank.txt")
      File.write!(path, "   \n\n\t\n   \n")

      function = Tools.get_function("inspect_file", dir)
      assert {:ok, output} = invoke(function, %{"path" => "blank.txt"})

      assert output =~ "Non-blank lines: 0"
    end
  end

  describe "inspect_file behavior on binary files" do
    test "PNG-like file is reported as binary", %{tmp: dir} do
      # PNG magic bytes.
      png_header = <<137, 80, 78, 71, 13, 10, 26, 10>>
      path = Path.join(dir, "image.png")
      File.write!(path, png_header <> String.duplicate(<<0>>, 100))

      function = Tools.get_function("inspect_file", dir)
      assert {:ok, output} = invoke(function, %{"path" => "image.png"})

      assert output =~ "File: image.png"
      assert output =~ "binary"
      assert output =~ "do not use read_file"
      assert output =~ "Size: 108 bytes"
    end

    test "UTF-16 file is reported as binary (not transcoded)", %{tmp: dir} do
      # UTF-16 LE with BOM.
      path = Path.join(dir, "utf16.txt")

      File.write!(
        path,
        (<<0xFF, 0xFE>> <> "hello")
        |> :binary.bin_to_list()
        |> Enum.chunk_every(2)
        |> Enum.map(&[&1])
        |> List.flatten()
        |> :binary.list_to_bin()
      )

      function = Tools.get_function("inspect_file", dir)
      assert {:ok, output} = invoke(function, %{"path" => "utf16.txt"})

      assert output =~ "binary"
      assert output =~ "do not use read_file"
    end
  end

  describe "inspect_file error paths" do
    test "missing file returns a structured error", %{tmp: dir} do
      function = Tools.get_function("inspect_file", dir)
      assert {:error, msg} = invoke(function, %{"path" => "missing.txt"})

      assert msg =~ "File not found"
      assert msg =~ "missing.txt"
    end

    test "file larger than 100 MB is rejected without reading", %{tmp: dir} do
      # Write a 100 MB + 1 byte file. The size check happens
      # BEFORE the read so the test is fast — we never actually
      # load the content.
      path = Path.join(dir, "huge.bin")

      File.open!(path, [:write], fn handle ->
        # Write 100 MB then 1 extra byte. Using IO.binwrite of a
        # single 1 MB chunk in a tight loop is faster than building
        # a 100 MB binary in memory.
        chunk = :binary.copy(<<0>>, 1024 * 1024)

        for _ <- 1..100, do: IO.binwrite(handle, chunk)

        IO.binwrite(handle, <<0>>)
      end)

      function = Tools.get_function("inspect_file", dir)
      assert {:error, msg} = invoke(function, %{"path" => "huge.bin"})

      assert msg =~ "100 MB"
      assert msg =~ "wc -l"
      assert msg =~ "huge.bin"
    end
  end

  describe "inspect_file in get_functions/2" do
    test "inspect_file is included when added to a tool list", %{tmp: dir} do
      functions = Tools.get_functions(["inspect_file"], dir)
      assert length(functions) == 1
      assert hd(functions).name == "inspect_file"
    end

    test "inspect_file is filtered out when not in the tool list", %{tmp: dir} do
      functions = Tools.get_functions(["read_file"], dir)
      names = Enum.map(functions, & &1.name)
      refute "inspect_file" in names
    end
  end

  setup do
    # Use a unique tmp directory per test so parallel tests don't
    # collide on the same file path.
    dir = Path.join(System.tmp_dir!(), "nest_inspect_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp: dir}
  end

  # Helper to invoke a tool's function with permissive sandbox caps.
  # The inspect_file tool never writes, but it does read; the caps
  # map must include a readable path (the test's tmp dir).
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
