defmodule Nest.Tools.ReadFailureMessageTest do
  @moduledoc """
  Pins the agent-facing sentence each classified sandbox read failure produces,
  for `file-read` and `file-inspect` alike.

  `Nest.Sandbox.Failure` classifies bwrap's stderr into reasons (`:enoent`,
  `:eisdir`, `:read_permission_denied`, `:sandbox_setup_failed`,
  `:read_timeout`, `:read_cancelled`); each read tool maps those to its own
  wording. Those arms are unreachable from the happy-path tool tests, so they
  are pinned here, where a wording change is a visible test failure rather than
  a silent drift between the two tools.

  `:enoent` is not repeated: `tools_test.exs` and
  `tools_inspect_file_test.exs` already pin it. Two arms are absent because
  nothing can reach them:

    * `:read_timeout` needs a real `ShellCmd` timeout (60s for a read/stat),
      and no test may wait for one.
    * `file-inspect`'s `:eisdir` would need `stat` to refuse a directory, which
      it never does — `file-inspect` classifies a directory with `file` and
      never reads it, which the first test below asserts.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.LLM.Tool, as: Function
  alias Nest.Tools

  setup do
    # A workspace outside /tmp (the scratch dir is bound at /tmp, so a
    # /tmp-rooted workspace is rejected). Unique per test.
    ws =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_read_failure_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(ws)

    on_exit(fn ->
      if String.contains?(ws, "nest_read_failure"), do: File.rm_rf!(ws)
    end)

    caps = %{
      "net" => false,
      "fs" => %{"read" => ["/"], "write" => ["/", ":workspace"]}
    }

    %{ws: ws, tmp_path: nil, caps: caps}
  end

  test "a directory is 'not a file' for file-read; file-inspect never reads it", ctx do
    File.mkdir_p!(Path.join(ctx.ws, "a-dir"))

    assert {:error, read_msg} = read_tool(ctx, %{"path" => "a-dir"})
    assert read_msg =~ "Not a file"
    assert read_msg =~ "a-dir"

    # `file-inspect` classifies the directory with `file` and stops there, so it
    # has no directory read to fail — hence no reachable `:eisdir` arm.
    assert {:ok, inspect_out} = inspect_tool(ctx, %{"path" => "a-dir"})
    assert inspect_out =~ "Type: directory"
  end

  test "an unreadable path is a caps denial for both tools", ctx do
    locked = Path.join(ctx.ws, "locked")
    File.mkdir_p!(locked)
    File.write!(Path.join(locked, "f.txt"), "x")
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod(locked, 0o700) end)

    assert {:error, read_msg} = read_tool(ctx, %{"path" => "locked/f.txt"})
    assert read_msg =~ "Not permitted to read file by sandbox caps"
    assert read_msg =~ "locked/f.txt"

    assert {:error, inspect_msg} = inspect_tool(ctx, %{"path" => "locked/f.txt"})
    assert inspect_msg =~ "Not permitted to stat file by sandbox caps"

    # Restore before the fixture teardown so `rm_rf!` can empty the directory.
    File.chmod!(locked, 0o700)
  end

  test "a sandbox that cannot start is a Nest problem, not a missing file", ctx do
    # A project mount whose destination bwrap cannot create makes every command
    # in the sandbox fail to start.
    source = Path.join(ctx.ws, "project-src")
    mount = %{"dest" => "/absent-dir/mnt", "mode" => "tmp", "create" => false, "source" => source}
    broken = %{ctx | caps: put_in(ctx.caps, ["fs", "project"], [mount])}

    log =
      capture_log(fn ->
        assert {:error, read_msg} = read_tool(broken, %{"path" => "f.txt"})
        assert read_msg =~ "The sandbox failed to start"
        refute read_msg =~ "File not found"

        assert {:error, inspect_msg} = inspect_tool(broken, %{"path" => "f.txt"})
        assert inspect_msg =~ "The sandbox failed to start"
      end)

    assert log =~ "sandbox_setup_failed"
  end

  test "a cancelled read or stat is reported as cancelled", ctx do
    assert cancelled(:read, ctx) =~ "Read cancelled"
    assert cancelled(:inspect, ctx) =~ "Read cancelled"
  end

  test "a workspace that does not exist falls through to the generic arm", ctx do
    # Neither tool can resolve a path against a workspace that is gone, so the
    # reason is a message string rather than an atom and hits the catch-all.
    gone = %{ctx | ws: Path.join(ctx.ws, "missing")}

    assert {:error, read_msg} = read_tool(gone, %{"path" => "f.txt"})
    assert read_msg =~ "Cannot read file:"
    assert read_msg =~ "does not exist"

    assert {:error, inspect_msg} = inspect_tool(gone, %{"path" => "f.txt"})
    assert inspect_msg =~ "Cannot stat file:"
    assert inspect_msg =~ "does not exist"
  end

  # Run the tool in its own process with the stop already in that process's
  # mailbox, so the stale `:DOWN` a cancellation leaves behind dies with it:
  # `ShellCmd.collect_output/3` matches any `:DOWN`, not just its own os_pid, so
  # a second sandbox call in the same process would consume the first one's.
  defp cancelled(which, ctx) do
    Task.async(fn ->
      send(self(), {:stop_chat, self()})

      case which do
        :read -> read_tool(ctx, %{"path" => "f.txt"})
        :inspect -> inspect_tool(ctx, %{"path" => "f.txt"})
      end
    end)
    |> Task.await()
    |> then(fn {:error, msg} -> msg end)
  end

  defp read_tool(ctx, args), do: call("file-read", ctx, args)
  defp inspect_tool(ctx, args), do: call("file-inspect", ctx, args)

  defp call(name, ctx, args) do
    %Function{function: fun} = Tools.get_function(name, ctx.ws, ctx.tmp_path)
    fun.(args, %{caps: ctx.caps})
  end
end
