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
      # Use a directory outside of /tmp for workspaces to avoid conflicts with tmp bind mounts
      test_workspace = "/var/tmp/nest_tools_test_#{System.unique_integer([:positive])}"
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

      assert error_msg =~ "No such file or directory"
    end

    test "returns error when workspace is nil" do
      function = Tools.get_function("read_file", nil)

      assert {:error, "No workspace configured for this agent"} =
               Function.execute(function, %{"path" => "test.txt"}, nil)
    end
  end

  describe "write_file tool" do
    setup do
      # Use a directory outside of /tmp for workspaces to avoid conflicts with tmp bind mounts
      test_workspace = "/var/tmp/nest_tools_test_#{System.unique_integer([:positive])}"
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

    test "returns error when parent directory does not exist", %{workspace: workspace} do
      function = Tools.get_function("write_file", workspace)

      assert {:error, error_msg} =
               Function.execute(
                 function,
                 %{"path" => "subdir/nested/file.txt", "content" => "nested"},
                 nil
               )

      assert error_msg =~ "Directory nonexistent" or error_msg =~ "No such file"
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
      # Use a directory outside of /tmp for workspaces to avoid conflicts with tmp bind mounts
      test_workspace = "/var/tmp/nest_tools_test_#{System.unique_integer([:positive])}"
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

    test "can write to /tmp when tmp_path is provided", %{workspace: workspace} do
      # Create a dedicated tmp directory for this test
      agent_tmp =
        Path.join(System.tmp_dir!(), "test_agent_tmp_#{System.unique_integer([:positive])}")

      File.mkdir_p!(agent_tmp)

      on_exit(fn ->
        File.rm_rf(agent_tmp)
      end)

      function = Tools.get_function("shell_cmd", workspace, agent_tmp)

      # Try to write to /tmp - this should succeed when tmp_path is provided
      assert {:ok, result} =
               Function.execute(
                 function,
                 %{
                   "command" =>
                     "echo 'test content' > /tmp/test_file.txt && cat /tmp/test_file.txt"
                 },
                 nil
               )

      assert result =~ "test content"

      # Verify the file was actually written to the agent's tmp directory
      assert File.exists?(Path.join(agent_tmp, "test_file.txt"))
      assert File.read!(Path.join(agent_tmp, "test_file.txt")) == "test content\n"
    end

    test "returns placeholder message for commands with no output", %{workspace: workspace} do
      function = Tools.get_function("shell_cmd", workspace)

      # Command that produces no output
      assert {:ok, result} =
               Function.execute(
                 function,
                 %{"command" => "true"},
                 nil
               )

      assert result == "[Command executed successfully with no output]"
    end

    test "cannot write to /tmp when tmp_path is not provided", %{workspace: workspace} do
      function = Tools.get_function("shell_cmd", workspace, nil)

      # Try to write to /tmp - this should fail when no tmp_path is provided
      # (because /tmp is read-only in the sandbox without a bind mount)
      assert {:error, result} =
               Function.execute(function, %{"command" => "echo 'test' > /tmp/test_file.txt"}, nil)

      # Should fail with a read-only filesystem error
      assert result =~ "Read-only file system" or result =~ "Exit code"
    end

    test "can redirect stdout to /dev/null", %{workspace: workspace} do
      # Regression: previously the read-only bind of the host root shadowed
      # the devtmpfs at /dev, so `> /dev/null` failed with
      # "cannot create /dev/null: Permission denied".
      function = Tools.get_function("shell_cmd", workspace, nil)

      assert {:ok, result} =
               Function.execute(
                 function,
                 %{"command" => "echo hello > /dev/null && echo done"},
                 nil
               )

      assert result =~ "done"
      refute result =~ "Permission denied"
    end

    test "can redirect stderr to /dev/null", %{workspace: workspace} do
      function = Tools.get_function("shell_cmd", workspace, nil)

      # `ls /nonexistent 2>/dev/null` should suppress the "No such file"
      # error; only the trailing `&& echo done` should appear in output.
      assert {:ok, result} =
               Function.execute(
                 function,
                 %{"command" => "ls /nonexistent-path 2>/dev/null; echo done"},
                 nil
               )

      assert result =~ "done"
      refute result =~ "No such file"
      refute result =~ "Permission denied"
    end

    test "handles find with 2>/dev/null redirect", %{workspace: workspace} do
      # Mirrors the user-reported failing command: find a missing path
      # while redirecting stderr to /dev/null, then echo a marker. If /dev
      # is misconfigured, the shell prints "cannot create /dev/null" to
      # stderr which (since this command has no 2>/dev/null on the echo)
      # would be captured.
      function = Tools.get_function("shell_cmd", workspace, nil)

      assert {:ok, result} =
               Function.execute(
                 function,
                 %{
                   "command" => "find /nonexistent-path-xyz -name foo 2>/dev/null; echo marker"
                 },
                 nil
               )

      assert result =~ "marker"
      refute result =~ "Permission denied"
      refute result =~ "cannot create"
    end
  end
end
