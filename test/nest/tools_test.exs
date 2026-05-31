defmodule Nest.ToolsTest do
  use ExUnit.Case, async: true

  alias LangChain.Function
  alias Nest.Tools

  describe "get_functions/2" do
    test "returns empty list for empty tool names" do
      assert Tools.get_functions([], "/tmp") == []
    end

    test "returns only valid tools, filtering out unknown names" do
      functions =
        Tools.get_functions(["read_file", "unknown_tool", "write_file"], "/tmp")

      assert length(functions) == 2

      names = Enum.map(functions, & &1.name)
      assert "read_file" in names
      assert "write_file" in names
      refute "unknown_tool" in names
    end

    test "returns LangChain.Function structs" do
      [function] = Tools.get_functions(["read_file"], "/tmp")

      assert %Function{} = function
      assert function.name == "read_file"
      assert is_binary(function.description)
      assert function.parameters_schema != nil
    end
  end

  describe "get_function/2" do
    test "returns read_file function" do
      function = Tools.get_function("read_file", "/tmp")

      assert %Function{} = function
      assert function.name == "read_file"
      assert function.description =~ "Read"
    end

    test "returns write_file function" do
      function = Tools.get_function("write_file", "/tmp")

      assert %Function{} = function
      assert function.name == "write_file"
      assert function.description =~ "Write"
    end

    test "returns shell_cmd function" do
      function = Tools.get_function("shell_cmd", "/tmp")

      assert %Function{} = function
      assert function.name == "shell_cmd"
      assert function.description =~ "shell"
    end

    test "returns nil for unknown tool" do
      assert Tools.get_function("unknown_tool", "/tmp") == nil
    end
  end

  describe "read_file tool" do
    setup do
      # Create a temporary directory for testing
      tmp_dir = System.tmp_dir!()
      test_workspace = Path.join(tmp_dir, "nest_tools_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(test_workspace)

      on_exit(fn ->
        File.rm_rf!(test_workspace)
      end)

      {:ok, workspace: test_workspace}
    end

    test "reads file content successfully", %{workspace: workspace} do
      test_file = Path.join(workspace, "test.txt")
      File.write!(test_file, "Hello, World!")

      function = Tools.get_function("read_file", workspace)
      assert {:ok, result} = Function.execute(function, %{"path" => "test.txt"}, nil)
      assert result == "Hello, World!"
    end

    test "returns error for non-existent file", %{workspace: workspace} do
      function = Tools.get_function("read_file", workspace)

      assert {:error, error_msg} =
               Function.execute(function, %{"path" => "nonexistent.txt"}, nil)

      assert error_msg =~ "Failed to read"
    end

    test "returns error when workspace is nil" do
      function = Tools.get_function("read_file", nil)

      assert {:error, "No workspace configured for this agent"} =
               Function.execute(function, %{"path" => "test.txt"}, nil)
    end
  end

  describe "write_file tool" do
    setup do
      tmp_dir = System.tmp_dir!()
      test_workspace = Path.join(tmp_dir, "nest_tools_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(test_workspace)

      on_exit(fn ->
        File.rm_rf!(test_workspace)
      end)

      {:ok, workspace: test_workspace}
    end

    test "writes file content successfully", %{workspace: workspace} do
      function = Tools.get_function("write_file", workspace)

      assert {:ok, result} =
               Function.execute(
                 function,
                 %{"path" => "output.txt", "content" => "Test content"},
                 nil
               )

      assert result =~ "Successfully wrote"

      written = File.read!(Path.join(workspace, "output.txt"))
      assert written == "Test content"
    end

    test "creates parent directories", %{workspace: workspace} do
      function = Tools.get_function("write_file", workspace)

      assert {:ok, _} =
               Function.execute(
                 function,
                 %{"path" => "subdir/nested/file.txt", "content" => "nested"},
                 nil
               )

      assert File.exists?(Path.join(workspace, "subdir/nested/file.txt"))
    end

    test "overwrites existing files", %{workspace: workspace} do
      test_file = Path.join(workspace, "existing.txt")
      File.write!(test_file, "old content")

      function = Tools.get_function("write_file", workspace)

      assert {:ok, _} =
               Function.execute(
                 function,
                 %{"path" => "existing.txt", "content" => "new content"},
                 nil
               )

      assert File.read!(test_file) == "new content"
    end

    test "returns error when workspace is nil" do
      function = Tools.get_function("write_file", nil)

      assert {:error, "No workspace configured for this agent"} =
               Function.execute(function, %{"path" => "test.txt", "content" => "test"}, nil)
    end
  end

  describe "shell_cmd tool" do
    setup do
      tmp_dir = System.tmp_dir!()
      test_workspace = Path.join(tmp_dir, "nest_tools_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(test_workspace)

      on_exit(fn ->
        File.rm_rf!(test_workspace)
      end)

      {:ok, workspace: test_workspace}
    end

    test "executes command and returns output", %{workspace: workspace} do
      function = Tools.get_function("shell_cmd", workspace)

      assert {:ok, result} = Function.execute(function, %{"command" => "echo hello"}, nil)
      assert result =~ "hello"
    end

    test "returns error for failed commands", %{workspace: workspace} do
      function = Tools.get_function("shell_cmd", workspace)

      assert {:error, result} = Function.execute(function, %{"command" => "exit 1"}, nil)
      assert result =~ "Exit code"
    end

    test "captures stderr", %{workspace: workspace} do
      function = Tools.get_function("shell_cmd", workspace)

      assert {:ok, result} = Function.execute(function, %{"command" => "echo error >&2"}, nil)
      assert result =~ "error"
    end

    test "handles command in workspace", %{workspace: workspace} do
      File.write!(Path.join(workspace, "test.txt"), "workspace file")

      function = Tools.get_function("shell_cmd", workspace)

      assert {:ok, result} = Function.execute(function, %{"command" => "cat test.txt"}, nil)
      assert result =~ "workspace file"
    end
  end
end
