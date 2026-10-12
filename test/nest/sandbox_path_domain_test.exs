defmodule Nest.SandboxPathDomainTest do
  @moduledoc """
  Guard: every path an agent sees is a sandbox path.

  An agent names exactly one domain of paths. The space scratch dir is bound at
  `/tmp`, so an agent's own scratch directory is `/tmp/<agent>/...`; the
  workspace is bound at its own path. The two directories those binds are made
  from travel in one `Nest.Sandbox.Mounts` value; `Nest.Sandbox` is what turns
  it into binds, and no module outside the boundary needs a directory in order
  to name a path an agent uses. These tests pin that stat/glob/read return
  paths in the agent's domain, that the `/tmp` bind source is exactly the
  scratch root `Nest.Sandbox.Paths` derives, that a result or a pointer never
  carries a directory the sandbox binds, and that read/stat/glob execute inside
  bwrap rather than against the host.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts

  setup do
    unique = System.unique_integer([:positive])

    # A workspace outside /tmp, so the space bind does not shadow it.
    workspace = Path.join([File.cwd!(), "_build", "tmp", "nest_path_domain_ws_#{unique}"])
    File.mkdir_p!(workspace)

    root = Path.join(System.tmp_dir!(), "nest_path_domain_#{unique}")
    agent = "agent-#{unique}"
    scratch = Path.join([root, "space-1", agent])
    File.mkdir_p!(scratch)

    on_exit(fn ->
      if String.contains?(workspace, "nest_path_domain_ws"), do: File.rm_rf!(workspace)
      if String.contains?(root, "nest_path_domain"), do: File.rm_rf(root)
    end)

    %{
      workspace: workspace,
      root: root,
      agent: agent,
      scratch: scratch,
      mounts: Mounts.new(workspace, scratch),
      caps: Sandbox.default_caps()
    }
  end

  test "the /tmp bind source matches the translation root, and stat/glob/read resolve it", ctx do
    File.write!(Path.join(ctx.scratch, "report.txt"), "hello")
    sandbox_file = "/tmp/#{ctx.agent}/report.txt"

    # The bind source `Sandbox.build/2` emits for `/tmp` is exactly the scratch
    # root `Nest.Sandbox.Paths` derives — so the bind layout and the reported
    # path cannot drift apart.
    {:ok, args} = Sandbox.build(ctx.caps, ctx.mounts)
    assert bind_source_for(args, "/tmp") == Nest.FSPath.canonical(Path.dirname(ctx.scratch))

    # glob returns the sandbox spelling only.
    assert {:ok, [^sandbox_file]} =
             Sandbox.glob("/tmp/#{ctx.agent}/*.txt", ctx.caps, ctx.mounts)

    assert {:ok, %{size: 5}} =
             Sandbox.stat(sandbox_file, ctx.caps, ctx.mounts)

    assert {:ok, "hello"} =
             Sandbox.read(sandbox_file, ctx.caps, ctx.mounts)
  end

  test "glob returns only paths in the agent's domain", ctx do
    File.write!(Path.join(ctx.scratch, "a.txt"), "x")

    assert {:ok, files} =
             Sandbox.glob("/tmp/#{ctx.agent}/*", ctx.caps, ctx.mounts)

    assert files == ["/tmp/#{ctx.agent}/a.txt"]
    refute Enum.any?(files, &String.contains?(&1, ctx.scratch))
    refute Enum.any?(files, &String.contains?(&1, ctx.root))
  end

  test "Overflow offload pointers name the agent's own path", ctx do
    path = Overflow.write("body", %{mounts: ctx.mounts}, "probe", "txt")

    assert path =~ "/tmp/#{ctx.agent}/"
    refute path =~ ctx.scratch
    # The bytes really landed at the host backing path.
    assert File.read!(Path.join(ctx.scratch, Path.basename(path))) == "body"
  end

  # ---- the review's "configurations": host-vs-bwrap disagreements ----

  test "a symlink to /tmp inside the scratch dir resolves to the scratch root, not the host",
       ctx do
    # A symlink to `/tmp` in the agent's scratch dir. Inside the sandbox `/tmp`
    # is the scratch bind, so following it must list the scratch root (the
    # space dir); the host `/tmp` must never appear.
    File.ln_s!("/tmp", Path.join(ctx.scratch, "t"))
    File.write!(Path.join([ctx.root, "space-1", "shared.txt"]), "scratch")

    assert {:ok, files} =
             Sandbox.glob("/tmp/#{ctx.agent}/t/*", ctx.caps, ctx.mounts)

    assert "/tmp/#{ctx.agent}/t/shared.txt" in files
    refute Enum.any?(files, &String.contains?(&1, ctx.root))
  end

  test "a workspace at or under /tmp is rejected for stat, read, and glob alike", ctx do
    ws = Path.join(System.tmp_dir!(), "nest_shadowed_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> rm_tmp!(ws, "nest_shadowed_ws_") end)

    target = Path.join(ws, "f.txt")

    assert {:error, stat_msg} = Sandbox.stat(target, ctx.caps, Mounts.new(ws, ctx.scratch))
    assert {:error, read_msg} = Sandbox.read(target, ctx.caps, Mounts.new(ws, ctx.scratch))

    assert {:error, glob_msg} =
             Sandbox.glob(Path.join(ws, "*"), ctx.caps, Mounts.new(ws, ctx.scratch))

    for msg <- [stat_msg, read_msg, glob_msg] do
      assert msg =~ "must not be at or under /tmp"
    end
  end

  test "a project tmp mount with an absent out-of-workspace destination fails every op", ctx do
    source = Path.join(ctx.root, "project-src")
    mount = %{"dest" => "/absent-dir/mnt", "mode" => "tmp", "create" => false, "source" => source}
    caps = put_in(ctx.caps, ["fs", "project"], [mount])

    # A bwrap setup failure is the unexpected case, so read/stat/glob all log
    # it (and report it) rather than failing silently.
    log =
      capture_log(fn ->
        assert {:error, :sandbox_setup_failed} =
                 Sandbox.stat("/etc/hostname", caps, ctx.mounts)

        assert {:error, :sandbox_setup_failed} =
                 Sandbox.glob("/etc/*", caps, ctx.mounts)

        assert {:error, :sandbox_setup_failed} =
                 Sandbox.read("/etc/hostname", caps, ctx.mounts)
      end)

    assert log =~ "Nest.Sandbox.stat: sandbox_setup_failed"
    assert log =~ "Nest.Sandbox.glob: sandbox_setup_failed"
    assert log =~ "Nest.Sandbox.read: sandbox_setup_failed"
  end

  test "a masked .nest is a char device for stat; reading it is denied", ctx do
    nest = Path.join(ctx.workspace, ".nest")
    caps = put_in(ctx.caps, ["fs", "protected"], [%{"path" => nest, "source" => "/dev/null"}])

    # `--ro-bind` mounts with `nodev`, so the masked char device is unusable:
    # stat sees a device, but opening it is denied (not a silent empty read).
    assert {:ok, %File.Stat{type: :device}} =
             Sandbox.stat(nest, caps, ctx.mounts)

    assert {:error, :read_permission_denied} =
             Sandbox.read(nest, caps, ctx.mounts)
  end

  test "reading a directory is :eisdir", ctx do
    dir = Path.join(ctx.workspace, "a-dir")
    File.mkdir_p!(dir)

    # A directory read is an ordinary tool outcome, so the classifier reports it
    # without logging. That quiet half of the policy is deliberately not
    # asserted — a `refute` on captured logs is unsound (`capture_log` collects
    # every process's logs) — and the loud half is asserted positively by the
    # sandbox-setup-failure test above.
    assert {:error, :eisdir} = Sandbox.read(dir, ctx.caps, ctx.mounts)
  end

  test "a /tmp write with no scratch dir is refused by the mount, not by a Nest check", ctx do
    # `default_caps` grants the symbolic /tmp write, but there is no scratch dir
    # to honor it, so /tmp stays the read-only host /tmp. The refusal comes from
    # the mount: bwrap is the only validator for what a path may do.
    log =
      capture_log(fn ->
        assert {:error, msg} =
                 Sandbox.write("/tmp/thing.txt", "x", ctx.caps, Mounts.new(ctx.workspace, nil))

        # The kernel's read-only failure, not a Nest-authored message. Assert
        # the exit code rather than the (locale-dependent) kernel text.
        assert msg =~ "Exit code"
      end)

    assert log =~ "bwrap exited non-zero"

    assert {:ok, _} =
             Sandbox.write(
               Path.join(ctx.workspace, "ok.txt"),
               "x",
               ctx.caps,
               Mounts.new(ctx.workspace, nil)
             )
  end

  # The sandbox's filesystem view is bwrap's view: `read`, `stat`, and `glob`
  # must execute inside bwrap, never against the host. A source scan is a weak
  # guard (it cannot see `apply/3`, an aliased `File`, `System.cmd`, or
  # `Port.open`), so this checks the AST for the specific host-read APIs a
  # host-side fast path would use, rather than a substring a review already
  # defeated by spelling the call differently.
  @sandbox_sources [
    "lib/nest/sandbox.ex",
    "lib/nest/sandbox/glob.ex",
    "lib/nest/sandbox/paths.ex",
    "lib/nest/sandbox/shell_jobs.ex",
    "lib/nest/tools/shell_cmd.ex"
  ]

  # Filesystem reads/stats/opens on the host that would bypass bwrap.
  # `File.dir?`, `File.exists?`, `File.rm`, `File.mkdir_p!`, `File.write!`
  # (staging) and the `Paths` string helpers stay allowed.
  @host_read_calls [
    {:file, :read},
    {:file, :read!},
    {:file, :stat},
    {:file, :lstat},
    {:file, :ls},
    {:file, :regular?},
    {:file, :stream!},
    {:file, :open},
    {:file, :open!},
    {:file, :read_file},
    {:file, :pread},
    {:io, :read},
    {:io, :binread}
  ]

  # The only reads on the host allowed in the scanned files. `Sandbox.ShellJobs`
  # reads its own job log: a Nest artifact written by Nest and exposed with the
  # same bytes by the mount, not an agent-visible read, so it is allowlisted
  # explicitly. A *second* such read in that file still fails the guard.
  @allowed_host_reads %{
    "lib/nest/sandbox/shell_jobs.ex" => [{:file, :read}]
  }

  test "read/stat/glob execute inside bwrap, not against the host (AST guard)" do
    for path <- @sandbox_sources do
      ast = path |> File.read!() |> Code.string_to_quoted!()
      offenders = ast |> host_read_calls() |> Enum.sort()
      allowed = Map.get(@allowed_host_reads, path, [])

      assert offenders == allowed,
             "#{path}: prohibited host filesystem reads/stats " <>
               "#{inspect(offenders -- allowed)} (allowed: #{inspect(allowed)})"
    end
  end

  defp host_read_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, host_read_call(node, acc)}
      end)

    Enum.reverse(calls)
  end

  defp host_read_call({{:., _meta, [mod, fun]}, _call_meta, _args}, acc) do
    if {module_of(mod), fun} in @host_read_calls do
      [{module_of(mod), fun} | acc]
    else
      acc
    end
  end

  defp host_read_call(_node, acc), do: acc

  defp module_of({:__aliases__, _, [:File]}), do: :file
  defp module_of({:__aliases__, _, [:IO]}), do: :io
  defp module_of(:file), do: :file
  defp module_of(:io), do: :io
  defp module_of(_), do: nil

  defp bind_source_for(args, dest) do
    args
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      ["--bind", source, ^dest] -> source
      _ -> nil
    end)
  end
end
