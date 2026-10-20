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
  alias Nest.Sandbox.Mounts
  alias Nest.Tools

  setup do
    unique = System.unique_integer([:positive])

    # A workspace outside /tmp: the space dir is bound at /tmp, so a
    # workspace under /tmp would be shadowed inside the sandbox.
    workspace = Path.join([File.cwd!(), "_build", "tmp", "nest_tools_spelling_#{unique}"])
    File.mkdir_p!(workspace)

    # The real scratch shape, with the root under /tmp so a scratch file's
    # own directory is shadowed inside the sandbox (which is what makes the
    # "a path outside the agent's domain fails" assertions meaningful).
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
      sandbox_file: "/tmp/#{agent}/report.txt",
      outside_file: Path.join(tmp_path, "report.txt"),
      caps: Sandbox.default_caps()
    }
  end

  test "every file tool addresses the agent's own paths; nothing else resolves", %{
    workspace: workspace,
    tmp_path: tmp_path,
    sandbox_file: sandbox_file,
    outside_file: outside_file,
    caps: caps
  } do
    write = Tools.get_function("file-write", Mounts.new(workspace, tmp_path))
    read = Tools.get_function("file-read", Mounts.new(workspace, tmp_path))
    edit = Tools.get_function("file-edit", Mounts.new(workspace, tmp_path))
    inspect = Tools.get_function("file-inspect", Mounts.new(workspace, tmp_path))
    shell = Tools.get_function("shell-cmd", Mounts.new(workspace, tmp_path))

    log =
      capture_log(fn ->
        # `file-write`'s advertised path is the sandbox path: the bytes land
        # under the agent's scratch directory.
        assert {:ok, _} =
                 write.function.(%{"path" => sandbox_file, "content" => "hello"}, %{caps: caps})

        assert File.read!(outside_file) == "hello"

        # ... and a path outside the agent's domain does not resolve either.
        assert {:error, message} =
                 write.function.(%{"path" => outside_file, "content" => "nope"}, %{caps: caps})

        assert message =~ "No such file"

        # `file-read` sees the same file through the same spelling.
        assert {:ok, "hello"} = read.function.(%{"path" => sandbox_file}, %{caps: caps})

        # `file-edit` reads and writes the same file through the sandbox
        # spelling (this could not work under the old split-path design).
        assert {:ok, _} =
                 edit.function.(
                   %{"path" => sandbox_file, "old_text" => "hello", "new_text" => "world"},
                   %{caps: caps}
                 )

        assert {:ok, "world"} = read.function.(%{"path" => sandbox_file}, %{caps: caps})

        # `file-inspect` operates on the same spelling.
        assert {:ok, _} = inspect.function.(%{"path" => sandbox_file}, %{caps: caps})

        # `shell-cmd` sees the same file through the same spelling.
        assert {:ok, "world"} =
                 shell.function.(%{"command" => "cat #{sandbox_file}"}, %{caps: caps})

        # ... and a path outside the agent's domain does not resolve for a read.
        assert {:error, message} = read.function.(%{"path" => outside_file}, %{caps: caps})
        assert message =~ "File not found"
      end)

    # The deliberate failures above are bwrap non-zero exits.
    assert log =~ "bwrap exited non-zero"
  end

  test "no tool description advertises a scratch path any more", %{
    workspace: workspace,
    tmp_path: tmp_path
  } do
    # The "your own scratch directory is /tmp/<agent>/" sentence used to be
    # appended to every path-taking description. It now lives once in the
    # agent's system prompt (`Nest.Agents.Agent.SystemPrompt`), so a
    # description must not depend on `tmp_path` at all: it can neither
    # mention the host scratch path nor the sandbox spelling, because both
    # are derived from `tmp_path` and it is unique to this run.
    for name <- [
          "shell-cmd",
          "shell-list",
          "file-write",
          "file-read",
          "file-edit",
          "file-inspect"
        ] do
      with_tmp = Tools.get_function(name, Mounts.new(workspace, tmp_path)).description
      without_tmp = Tools.get_function(name, Mounts.new(workspace, nil)).description

      assert with_tmp == without_tmp, "#{name}'s description still depends on tmp_path"
    end
  end
end
