defmodule Nest.ToolsTest do
  use ExUnit.Case, async: true

  alias Nest.LLM.Tool, as: Function
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

    test "returns Nest.LLM.Tool structs" do
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
      assert {:ok, result} = function.function.(%{"path" => "test.txt"}, nil)
      assert result == "Hello, World!"
    end

    test "returns error for non-existent file", %{workspace: workspace} do
      function = Tools.get_function("read_file", workspace)

      assert {:error, error_msg} =
               function.function.(%{"path" => "nonexistent.txt"}, nil)

      assert error_msg =~ "No such file or directory"
    end

    test "returns error when workspace is nil" do
      function = Tools.get_function("read_file", nil)

      assert {:error, "No workspace configured for this agent"} =
               function.function.(%{"path" => "test.txt"}, nil)
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
               function.function.(%{"path" => "test.txt", "content" => "test"}, nil)
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

      assert {:ok, result} = function.function.(%{"command" => "echo hello"}, nil)
      assert result =~ "hello"
    end

    test "returns error for failed commands", %{workspace: workspace} do
      function = Tools.get_function("shell_cmd", workspace)

      assert {:error, result} = function.function.(%{"command" => "exit 1"}, nil)
      assert result =~ "Exit code"
    end

    test "captures stderr", %{workspace: workspace} do
      function = Tools.get_function("shell_cmd", workspace)

      assert {:ok, result} = function.function.(%{"command" => "echo error >&2"}, nil)
      assert result =~ "error"
    end

    test "handles command in workspace", %{workspace: workspace} do
      File.write!(Path.join(workspace, "test.txt"), "workspace file")

      function = Tools.get_function("shell_cmd", workspace)

      assert {:ok, result} = function.function.(%{"command" => "cat test.txt"}, nil)
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
               function.function.(%{"command" => "echo 'test' > /tmp/test_file.txt"}, nil)

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

  describe "caps threading through context" do
    setup do
      test_workspace = "/var/tmp/nest_caps_test_#{System.unique_integer([:positive])}"
      File.mkdir_p!(test_workspace)
      on_exit(fn -> File.rm_rf!(test_workspace) end)
      {:ok, workspace: test_workspace}
    end

    test "read_file ignores caps (read is always allowed in the host bind)", %{
      workspace: workspace
    } do
      test_file = Path.join(workspace, "x.txt")
      File.write!(test_file, "ok")

      function = Tools.get_function("read_file", workspace)
      # Read-only caps still allow reads (the ro-bind of / covers
      # the workspace).
      caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}

      assert {:ok, "ok"} = function.function.(%{"path" => "x.txt"}, %{caps: caps})
    end

    test "write_file fails when :workspace is not in the write list", %{workspace: workspace} do
      function = Tools.get_function("write_file", workspace)
      # Plan mode caps: write: ["/tmp"] but no :workspace. The
      # workspace stays read-only via the ro-bind of /, so writes
      # fail at the kernel level.
      caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}

      assert {:error, error_msg} =
               Function.execute(
                 function,
                 %{"path" => "out.txt", "content" => "data"},
                 %{caps: caps}
               )

      assert error_msg =~ "Read-only file system"
    end

    test "write_file succeeds when :workspace is in the write list", %{workspace: workspace} do
      function = Tools.get_function("write_file", workspace)
      caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}}

      assert {:ok, _} =
               Function.execute(
                 function,
                 %{"path" => "out.txt", "content" => "data"},
                 %{caps: caps}
               )
    end

    test "shell_cmd with net=true caps passes --share-net through", %{workspace: workspace} do
      # We can't directly observe bwrap args, but we can verify the
      # tool still runs to completion when net=true.
      function = Tools.get_function("shell_cmd", workspace, nil)
      caps = %{"net" => true, "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}}

      assert {:ok, result} =
               Function.execute(
                 function,
                 %{"command" => "echo hello"},
                 %{caps: caps}
               )

      assert result =~ "hello"
    end

    test "tool with nil context falls back to default caps", %{workspace: workspace} do
      # The legacy path: callers that pass nil context get default caps.
      function = Tools.get_function("shell_cmd", workspace, nil)
      assert {:ok, result} = function.function.(%{"command" => "echo ok"}, nil)
      assert result =~ "ok"
    end

    test "tool with context that has no caps key falls back to default caps", %{
      workspace: workspace
    } do
      # The catch-all path in caps_from_context/1: context is a map
      # but lacks the :caps key.
      function = Tools.get_function("shell_cmd", workspace, nil)

      assert {:ok, result} =
               function.function.(%{"command" => "echo ok"}, %{other: "thing"})

      assert result =~ "ok"
    end
  end

  describe "max_result_tokens" do
    test "read_file has a 8192-token default" do
      function = Tools.get_function("read_file", "/tmp")
      assert function.max_result_tokens == 8192
    end

    test "shell_cmd has a 8192-token default" do
      function = Tools.get_function("shell_cmd", "/tmp")
      assert function.max_result_tokens == 8192
    end

    test "write_file has a 256-token default (result is naturally small)" do
      function = Tools.get_function("write_file", "/tmp")
      assert function.max_result_tokens == 256
    end

    test "context tool exists with 512-token cap" do
      function = Tools.get_function("context", "/tmp")
      assert function != nil
      assert function.name == "context"
      assert function.max_result_tokens == 512
    end

    test "context is included when added to a tool list" do
      functions = Tools.get_functions(["context"], "/tmp")
      assert length(functions) == 1
      assert hd(functions).name == "context"
    end

    test "max_result_tokens is exposed in the parameters schema" do
      function = Tools.get_function("read_file", "/tmp")
      schema = function.parameters_schema
      assert Map.has_key?(schema["properties"], "max_result_tokens")
      assert schema["properties"]["max_result_tokens"]["type"] == "integer"
    end

    test "max_result_tokens is not in the required list (it's optional)" do
      function = Tools.get_function("read_file", "/tmp")
      required = function.parameters_schema["required"] || []
      refute "max_result_tokens" in required
    end
  end
end
