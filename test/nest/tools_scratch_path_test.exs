defmodule Nest.ToolsScratchPathTest do
  @moduledoc """
  Behavioural check that every file tool addresses the same sandbox-domain
  scratch spelling (`/tmp/<agent>/...`).

  The space dir is bound at `/tmp`, so `/tmp/<agent>/` is the only spelling
  the agent is ever told about or may hand back. The host backing path
  (`<space_dir>/<agent>/...`) must not resolve for any tool and must not
  appear in any tool description.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Sandbox
  alias Nest.Tools

  setup do
    unique = System.unique_integer([:positive])

    # A workspace outside /tmp: the space dir is bound at /tmp, so a
    # workspace under /tmp would be shadowed inside the sandbox.
    workspace = Path.join([File.cwd!(), "_build", "tmp", "nest_tools_spelling_#{unique}"])
    File.mkdir_p!(workspace)

    # The real scratch shape, with the root under /tmp so a scratch
    # file's host path is shadowed inside the sandbox (which is what
    # makes the "wrong spelling fails" assertions meaningful).
    root = Path.join(System.tmp_dir!(), "nest_tools_spelling_#{unique}")
    agent = "agent-#{unique}"
    tmp_path = Path.join([root, "space-1", agent])

    on_exit(fn ->
      if String.contains?(workspace, "nest_tools_spelling"), do: File.rm_rf!(workspace)
      if String.contains?(root, "nest_tools_spelling"), do: File.rm_rf(root)
    end)

    %{
      workspace: workspace,
      tmp_path: tmp_path,
      agent: agent,
      sandbox_file: "/tmp/#{agent}/report.txt",
      host_file: Path.join(tmp_path, "report.txt"),
      caps: Sandbox.default_caps()
    }
  end

  test "every file tool uses the sandbox spelling; the host spelling never resolves", %{
    workspace: workspace,
    tmp_path: tmp_path,
    sandbox_file: sandbox_file,
    host_file: host_file,
    caps: caps
  } do
    write = Tools.get_function("file-write", workspace, tmp_path)
    read = Tools.get_function("file-read", workspace, tmp_path)
    edit = Tools.get_function("file-edit", workspace, tmp_path)
    inspect = Tools.get_function("file-inspect", workspace, tmp_path)
    shell = Tools.get_function("shell-cmd", workspace, tmp_path)

    log =
      capture_log(fn ->
        # `file-write`'s advertised spelling is the sandbox path: the file
        # lands on the host under `tmp_path`.
        assert {:ok, _} =
                 write.function.(%{"path" => sandbox_file, "content" => "hello"}, %{caps: caps})

        assert File.read!(host_file) == "hello"

        # ... and the host spelling does not resolve for a write either.
        assert {:error, message} =
                 write.function.(%{"path" => host_file, "content" => "nope"}, %{caps: caps})

        assert message =~ "No such file"

        # `file-read` sees the same file through the same spelling.
        assert {:ok, "hello"} = read.function.(%{"path" => sandbox_file}, %{caps: caps})

        # `file-edit` reads and writes the same file through the sandbox
        # spelling (this could not work under the old split-path design).
        assert {:ok, edit_message} =
                 edit.function.(
                   %{"path" => sandbox_file, "old_text" => "hello", "new_text" => "world"},
                   %{caps: caps}
                 )

        assert edit_message =~ "Replaced 1"
        assert {:ok, "world"} = read.function.(%{"path" => sandbox_file}, %{caps: caps})

        # `file-inspect` operates on the same spelling.
        assert {:ok, inspect_out} = inspect.function.(%{"path" => sandbox_file}, %{caps: caps})
        assert inspect_out =~ "File: #{sandbox_file}"

        # `shell-cmd` sees the same file through the same spelling.
        assert {:ok, "world"} =
                 shell.function.(%{"command" => "cat #{sandbox_file}"}, %{caps: caps})

        # ... and the host spelling does not resolve for a read.
        assert {:error, message} = read.function.(%{"path" => host_file}, %{caps: caps})
        assert message =~ "File not found"
      end)

    # The deliberate failures above are bwrap non-zero exits.
    assert log =~ "bwrap exited non-zero"
  end

  test "no tool description mentions the host scratch path", %{
    workspace: workspace,
    tmp_path: tmp_path,
    agent: agent
  } do
    for name <- [
          "shell-cmd",
          "shell-list",
          "file-write",
          "file-read",
          "file-edit",
          "file-inspect"
        ] do
      description = Tools.get_function(name, workspace, tmp_path).description

      refute description =~ tmp_path, "#{name} leaked the host scratch path"
      assert description =~ "/tmp/#{agent}/", "#{name} did not advertise the sandbox spelling"
    end
  end
end
