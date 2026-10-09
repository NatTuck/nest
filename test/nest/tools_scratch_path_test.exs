defmodule Nest.ToolsScratchPathTest do
  @moduledoc """
  Behavioural check that each noted tool's advertised scratch-path spelling
  is the one that actually resolves: `shell-cmd`/`file-write` use the
  sandbox spelling (the space dir is bound at `/tmp`), `file-read` uses the
  host spelling. Each tool's *other* spelling is asserted to fail, so a
  future change to the bind or the tools cannot silently swap them.

  `file-edit`/`file-inspect` are deliberately absent: they mix the host read
  fast-path with bwrap, so neither spelling works for a scratch file today.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Sandbox
  alias Nest.Tools

  setup do
    # A workspace outside /tmp: the space dir is bound at /tmp, so a
    # workspace under /tmp would be shadowed inside the sandbox.
    workspace =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_tools_spelling_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(workspace)

    # The real scratch shape, with the root under /tmp so a scratch
    # file's host path is shadowed inside the sandbox (which is what
    # makes the "wrong spelling fails" assertions meaningful).
    root =
      Path.join(System.tmp_dir!(), "nest_tools_spelling_#{System.unique_integer([:positive])}")

    agent = "agent-#{System.unique_integer([:positive])}"
    tmp_path = Path.join([root, "space-1", agent])

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf(root)
    end)

    %{
      workspace: workspace,
      tmp_path: tmp_path,
      sandbox_file: "/tmp/#{agent}/report.txt",
      host_file: Path.join(tmp_path, "report.txt"),
      caps: Sandbox.default_caps()
    }
  end

  test "each noted tool resolves its advertised spelling and rejects the other", %{
    workspace: workspace,
    tmp_path: tmp_path,
    sandbox_file: sandbox_file,
    host_file: host_file,
    caps: caps
  } do
    write = Tools.get_function("file-write", workspace, tmp_path)
    read = Tools.get_function("file-read", workspace, tmp_path)
    shell = Tools.get_function("shell-cmd", workspace, tmp_path)

    log =
      capture_log(fn ->
        # `file-write` advertises the sandbox spelling: it writes through
        # bwrap, so the file lands on the host under `tmp_path`.
        assert {:ok, _} =
                 write.function.(%{"path" => sandbox_file, "content" => "hello"}, %{caps: caps})

        assert File.read!(host_file) == "hello"

        # ... and the host spelling does not resolve inside bwrap.
        assert {:error, message} =
                 write.function.(%{"path" => host_file, "content" => "nope"}, %{caps: caps})

        assert message =~ "No such file"

        # `file-read` advertises the host spelling ...
        assert {:ok, "hello"} = read.function.(%{"path" => host_file}, %{caps: caps})

        # ... and the sandbox spelling does not resolve on the host.
        assert {:error, message} = read.function.(%{"path" => sandbox_file}, %{caps: caps})
        assert message =~ "File not found"

        # `shell-cmd` advertises the sandbox spelling ...
        assert {:ok, "hello"} =
                 shell.function.(%{"command" => "cat #{sandbox_file}"}, %{caps: caps})

        # ... and the host spelling is shadowed inside the sandbox.
        assert {:error, message} =
                 shell.function.(%{"command" => "cat #{host_file}"}, %{caps: caps})

        assert message =~ "No such file"
      end)

    # Both deliberate failures above are bwrap non-zero exits.
    assert log =~ "bwrap exited non-zero"
  end
end
