defmodule Nest.ToolsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.LLM.Tool, as: Function
  alias Nest.Tools

  describe "get_functions/2" do
    test "returns empty list for empty tool names" do
      assert Tools.get_functions([], "/tmp") == []
    end

    test "filters unknown names and logs a warning" do
      log =
        capture_log(fn ->
          functions = Tools.get_functions(["file-read", "unknown_tool", "file-write"], "/tmp")
          assert length(functions) == 2
          names = Enum.map(functions, & &1.name)
          assert "file-read" in names and "file-write" in names
          refute "unknown_tool" in names
        end)

      assert log =~ "unknown_tool"
    end

    test "returns Nest.LLM.Tool structs" do
      [function] = Tools.get_functions(["file-read"], "/tmp")

      assert %Function{} = function
      assert function.name == "file-read"
      assert is_binary(function.description)
      assert function.parameters_schema != nil
    end
  end

  describe "get_function/2" do
    test "returns read_file function" do
      function = Tools.get_function("file-read", "/tmp")

      assert %Function{} = function
      assert function.name == "file-read"
      assert function.description =~ "Read"
    end

    test "returns write_file function" do
      function = Tools.get_function("file-write", "/tmp")

      assert %Function{} = function
      assert function.name == "file-write"
      assert function.description =~ "Write"
    end

    test "returns shell_cmd function" do
      function = Tools.get_function("shell-cmd", "/tmp")

      assert %Function{} = function
      assert function.name == "shell-cmd"
      assert function.description =~ "shell"
    end

    test "returns nil for unknown tool" do
      assert Tools.get_function("unknown_tool", "/tmp") == nil
    end
  end

  describe "scratch-path descriptions" do
    test "names the scratch dir in the spelling each tool takes" do
      tmp_path = "/tmp/nest-1/space-7/agent-x"
      sandbox_path = "/tmp/agent-x/"

      # Shell tools run inside the sandbox; `file-write` also writes
      # through bwrap (`Sandbox.write/5`), so all name the sandbox path the
      # space dir is bound at — and never the host path.
      for name <- ["shell-cmd", "shell-list", "file-write"] do
        description = Tools.get_function(name, "/tmp", tmp_path).description

        assert description =~ sandbox_path
        assert description =~ "shared with your siblings"
        refute description =~ tmp_path
      end

      # `file-read` addresses a host path — and never the sandbox path.
      description = Tools.get_function("file-read", "/tmp", tmp_path).description
      assert description =~ tmp_path
      assert description =~ "shared with your siblings"
      refute description =~ sandbox_path

      # `file-edit`/`file-inspect` mix the host read fast-path and bwrap
      # writes/calls, so no single spelling is right and they carry no note.
      for name <- ["file-edit", "file-inspect"] do
        refute Tools.get_function(name, "/tmp", tmp_path).description =~ "scratch directory"
      end
    end

    test "omits the scratch note when no tmp dir is configured" do
      for name <- ["shell-cmd", "shell-list", "file-read", "file-write"] do
        description = Tools.get_function(name, "/tmp", nil).description

        refute description =~ "scratch directory"
      end
    end
  end

  describe "sub-agent tools" do
    test "models-list resolves to a registered tool" do
      function = Tools.get_function("models-list", "/tmp")

      assert %Function{} = function
      assert function.name == "models-list"
      assert function.description =~ "expose_models"
    end

    test "agents-spawn schema exposes the optional vocation, model, and async arguments" do
      function = Tools.get_function("agents-spawn", "/tmp")
      assert function.name == "agents-spawn"

      props = function.parameters_schema["properties"]
      assert props["vocation"]["type"] == "string"
      assert props["vocation"]["description"] =~ "vocation slug"
      refute "vocation" in (function.parameters_schema["required"] || [])

      assert props["model"]["type"] == "string"
      assert props["model"]["description"] =~ "provider/model-name"
      refute "model" in (function.parameters_schema["required"] || [])

      assert props["async"]["type"] == "boolean"
      assert props["async"]["default"] == false
      assert props["async"]["description"] =~ "message in your inbox"
      assert function.description =~ "arrives later as a message"
    end

    test "agents-query schema takes an optional async flag and timeout" do
      function = Tools.get_function("agents-query", "/tmp")
      assert function.name == "agents-query"

      props = function.parameters_schema["properties"]
      assert props["async"]["type"] == "boolean"
      assert props["async"]["default"] == false
      assert props["async"]["description"] =~ "message in your inbox"
      assert props["timeout"]["type"] == "integer"

      assert function.parameters_schema["required"] == ["name", "prompt"]
      assert function.description =~ "arrives later as a message"
    end

    test "agents-batch schema exposes items/glob/template with no required args" do
      function = Tools.get_function("agents-batch", "/tmp")
      assert function.name == "agents-batch"

      props = function.parameters_schema["properties"]
      assert props["items"]["type"] == "array"
      assert props["glob"]["type"] == "string"
      assert props["template"]["type"] == "string"
      assert props["on_error"]["enum"] == ["collect", "fail_fast"]

      # The items/XOR/glob shape is validated at runtime, so nothing is
      # required at the schema level.
      assert (function.parameters_schema["required"] || []) == []

      assert function.description =~ "aggregated result"
    end

    test "agents-send schema requires name and message" do
      function = Tools.get_function("agents-send", "/tmp")
      assert function.name == "agents-send"

      assert function.parameters_schema["required"] == ["name", "message"]
      assert function.parameters_schema["properties"]["name"]["type"] == "string"
      assert function.parameters_schema["properties"]["message"]["type"] == "string"
      assert function.description =~ "without waiting"
    end

    test "agents-wait schema takes an optional names list and timeout" do
      function = Tools.get_function("agents-wait", "/tmp")
      assert function.name == "agents-wait"

      props = function.parameters_schema["properties"]
      assert props["names"]["type"] == "array"
      assert props["names"]["items"] == %{"type" => "string"}
      assert props["timeout"]["type"] == "integer"

      # An empty list is meaningful ("every other agent"), so nothing is
      # required at the schema level.
      assert (function.parameters_schema["required"] || []) == []

      assert function.description =~ "already idle"
      assert function.description =~ "not an error"
    end
  end

  describe "file-read tool" do
    setup do
      # Project-relative tmp dir under _build/ — gitignored, always writable.
      test_workspace =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "nest_tools_test_#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(test_workspace)

      on_exit(fn ->
        File.rm_rf!(test_workspace)
      end)

      {:ok, workspace: test_workspace}
    end

    test "reads file content successfully", %{workspace: workspace} do
      test_file = Path.join(workspace, "test.txt")
      File.write!(test_file, "Hello, World!")

      function = Tools.get_function("file-read", workspace)
      assert {:ok, result} = function.function.(%{"path" => "test.txt"}, nil)
      assert result == "Hello, World!"
    end

    test "returns error for non-existent file", %{workspace: workspace} do
      function = Tools.get_function("file-read", workspace)

      assert {:error, error_msg} =
               function.function.(%{"path" => "nonexistent.txt"}, nil)

      assert error_msg =~ "File not found: nonexistent.txt"
    end

    test "returns error when workspace is nil" do
      function = Tools.get_function("file-read", nil)

      assert {:error, "No workspace configured for this agent"} =
               function.function.(%{"path" => "test.txt"}, nil)
    end

    test "returns a non-text error for NUL and invalid UTF-8", %{workspace: workspace} do
      # NUL is valid UTF-8, so it needs the explicit binary check.
      File.write!(Path.join(workspace, "nul.bin"), "text" <> <<0>> <> "more")
      File.write!(Path.join(workspace, "invalid.bin"), <<0xFF, 0xFE>>)

      function = Tools.get_function("file-read", workspace)

      for name <- ["nul.bin", "invalid.bin"] do
        assert {:error, error_msg} = function.function.(%{"path" => name}, nil)
        assert error_msg =~ "non-text"
        assert error_msg =~ "file-inspect"
      end
    end
  end

  describe "file-write tool" do
    setup do
      # Project-relative tmp dir under _build/ — gitignored, always writable.
      test_workspace =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "nest_tools_test_#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(test_workspace)

      on_exit(fn ->
        File.rm_rf!(test_workspace)
      end)

      {:ok, workspace: test_workspace}
    end

    test "writes file content successfully", %{workspace: workspace} do
      function = Tools.get_function("file-write", workspace)

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
      function = Tools.get_function("file-write", workspace)

      log =
        capture_log(fn ->
          assert {:error, error_msg} =
                   Function.execute(
                     function,
                     %{"path" => "subdir/nested/file.txt", "content" => "nested"},
                     nil
                   )

          assert error_msg =~ "Directory nonexistent" or error_msg =~ "No such file"
        end)

      # bwrap's non-zero exit is a deliberate diagnostic.
      assert log =~ "ShellCmd.execute: bwrap exited non-zero"

      # The wording is the shell's: dash says "Directory nonexistent", bash says "No such file or directory".
      assert log =~ "Directory nonexistent" or log =~ "No such file"
    end

    test "overwrites existing files", %{workspace: workspace} do
      test_file = Path.join(workspace, "existing.txt")
      File.write!(test_file, "old content")

      function = Tools.get_function("file-write", workspace)

      assert {:ok, _} =
               Function.execute(
                 function,
                 %{"path" => "existing.txt", "content" => "new content"},
                 nil
               )

      assert File.read!(test_file) == "new content"
    end

    test "returns error when workspace is nil" do
      function = Tools.get_function("file-write", nil)

      assert {:error, "No workspace configured for this agent"} =
               function.function.(%{"path" => "test.txt", "content" => "test"}, nil)
    end
  end

  describe "shell-cmd tool" do
    setup do
      # Project-relative tmp dir under _build/ — gitignored, always writable.
      test_workspace =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "nest_tools_test_#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(test_workspace)

      on_exit(fn ->
        File.rm_rf!(test_workspace)
      end)

      {:ok, workspace: test_workspace}
    end

    test "executes command and returns output", %{workspace: workspace} do
      function = Tools.get_function("shell-cmd", workspace)

      assert {:ok, result} = function.function.(%{"command" => "echo hello"}, nil)
      assert result =~ "hello"
    end

    test "returns error for failed commands", %{workspace: workspace} do
      function = Tools.get_function("shell-cmd", workspace)

      log =
        capture_log(fn ->
          assert {:error, result} = function.function.(%{"command" => "exit 1"}, nil)
          assert result =~ "Exit code"
        end)

      # bwrap's non-zero exit is a deliberate diagnostic.
      assert log =~ "ShellCmd.execute: bwrap exited non-zero"
      assert log =~ "exit_code=1"
    end

    test "captures stderr", %{workspace: workspace} do
      function = Tools.get_function("shell-cmd", workspace)

      assert {:ok, result} = function.function.(%{"command" => "echo error >&2"}, nil)
      assert result =~ "error"
    end

    test "handles command in workspace", %{workspace: workspace} do
      File.write!(Path.join(workspace, "test.txt"), "workspace file")

      function = Tools.get_function("shell-cmd", workspace)

      assert {:ok, result} = function.function.(%{"command" => "cat test.txt"}, nil)
      assert result =~ "workspace file"
    end

    test "can write to /tmp when tmp_path is provided", %{workspace: workspace} do
      # Space-scoped scratch layout: <space_dir>/<agent-name>, with the
      # space dir bound at /tmp inside the sandbox.
      space_dir =
        Path.join([System.tmp_dir!(), "nest_tools_space_#{System.unique_integer([:positive])}"])

      agent_name = "agent-#{System.unique_integer([:positive])}"
      agent_tmp = Path.join(space_dir, agent_name)
      File.mkdir_p!(agent_tmp)

      on_exit(fn ->
        File.rm_rf(space_dir)
      end)

      function = Tools.get_function("shell-cmd", workspace, agent_tmp)

      # Try to write to the agent's own /tmp subdir - this should succeed
      # when tmp_path is provided (the space dir is bound at /tmp).
      assert {:ok, result} =
               Function.execute(
                 function,
                 %{
                   "command" =>
                     "echo 'test content' > /tmp/#{agent_name}/test_file.txt && " <>
                       "cat /tmp/#{agent_name}/test_file.txt"
                 },
                 nil
               )

      assert result =~ "test content"

      # Verify the file was actually written to the agent's scratch dir.
      assert File.exists?(Path.join(agent_tmp, "test_file.txt"))
      assert File.read!(Path.join(agent_tmp, "test_file.txt")) == "test content\n"
    end

    test "returns placeholder message for commands with no output", %{workspace: workspace} do
      function = Tools.get_function("shell-cmd", workspace)

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
      function = Tools.get_function("shell-cmd", workspace, nil)

      # Try to write to /tmp - this should fail when no tmp_path is provided
      # (because /tmp is read-only in the sandbox without a bind mount)
      log =
        capture_log(fn ->
          assert {:error, result} =
                   function.function.(%{"command" => "echo 'test' > /tmp/test_file.txt"}, nil)

          # Should fail with a read-only filesystem error
          assert result =~ "Read-only file system" or result =~ "Exit code"
        end)

      # bwrap's non-zero exit is a deliberate diagnostic.
      assert log =~ "ShellCmd.execute: bwrap exited non-zero"
      assert log =~ "Read-only file system"
    end

    test "can redirect stdout to /dev/null", %{workspace: workspace} do
      # Regression: previously the read-only bind of the host root shadowed
      # the devtmpfs at /dev, so `> /dev/null` failed with "Permission denied".
      function = Tools.get_function("shell-cmd", workspace, nil)

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
      function = Tools.get_function("shell-cmd", workspace, nil)

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
      # Mirrors a user-reported failing command: find a missing path
      # while redirecting stderr to /dev/null, then echo a marker.
      function = Tools.get_function("shell-cmd", workspace, nil)

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
      # Project-relative tmp dir under _build/ — gitignored, always writable.
      test_workspace =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "nest_caps_test_#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(test_workspace)
      on_exit(fn -> File.rm_rf!(test_workspace) end)
      {:ok, workspace: test_workspace}
    end

    test "read_file ignores caps (read is always allowed in the host bind)", %{
      workspace: workspace
    } do
      test_file = Path.join(workspace, "x.txt")
      File.write!(test_file, "ok")

      function = Tools.get_function("file-read", workspace)
      # Read-only caps still allow reads (the ro-bind of / covers
      # the workspace).
      caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => []}}

      assert {:ok, "ok"} = function.function.(%{"path" => "x.txt"}, %{caps: caps})
    end

    test "write_file fails when :workspace is not in the write list", %{workspace: workspace} do
      function = Tools.get_function("file-write", workspace)
      # Plan mode caps: write: ["/tmp"] but no :workspace. The
      # workspace stays read-only via the ro-bind of /, so writes
      # fail at the kernel level.
      caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => ["/tmp"]}}

      log =
        capture_log(fn ->
          assert {:error, error_msg} =
                   Function.execute(
                     function,
                     %{"path" => "out.txt", "content" => "data"},
                     %{caps: caps}
                   )

          assert error_msg =~ "Read-only file system"
        end)

      # bwrap's non-zero exit is a deliberate diagnostic.
      assert log =~ "ShellCmd.execute: bwrap exited non-zero"
      assert log =~ "Read-only file system"
    end

    test "write_file succeeds when :workspace is in the write list", %{workspace: workspace} do
      function = Tools.get_function("file-write", workspace)
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
      function = Tools.get_function("shell-cmd", workspace, nil)
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
      function = Tools.get_function("shell-cmd", workspace, nil)
      assert {:ok, result} = function.function.(%{"command" => "echo ok"}, nil)
      assert result =~ "ok"
    end

    test "tool with context that has no caps key falls back to default caps", %{
      workspace: workspace
    } do
      # The catch-all path in caps_from_context/1: context is a map
      # but lacks the :caps key.
      function = Tools.get_function("shell-cmd", workspace, nil)

      assert {:ok, result} =
               function.function.(%{"command" => "echo ok"}, %{other: "thing"})

      assert result =~ "ok"
    end
  end

  describe "max_result_tokens" do
    test "Tool struct does not carry a per-tool max_result_tokens field; cap is enforced by BatchSizer" do
      for name <- ["file-read", "shell-cmd", "file-write", "context-check", "context-compact"] do
        function = Tools.get_function(name, "/tmp")

        refute Map.has_key?(function, :max_result_tokens),
               "#{name} still has a per-tool :max_result_tokens field; cap is enforced by BatchSizer"
      end
    end

    test "context-check is included when added to a tool list" do
      functions = Tools.get_functions(["context-check"], "/tmp")
      assert length(functions) == 1
      assert hd(functions).name == "context-check"
    end

    test "max_result_tokens is exposed in the parameters schema" do
      function = Tools.get_function("file-read", "/tmp")
      schema = function.parameters_schema
      assert Map.has_key?(schema["properties"], "max_result_tokens")
      assert schema["properties"]["max_result_tokens"]["type"] == "integer"
    end

    test "max_result_tokens is not in the required list (it's optional)" do
      function = Tools.get_function("file-read", "/tmp")
      required = function.parameters_schema["required"] || []
      refute "max_result_tokens" in required
    end
  end
end
