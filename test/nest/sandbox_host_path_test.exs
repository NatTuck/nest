defmodule Nest.SandboxHostPathTest do
  @moduledoc """
  Guard: the host scratch spelling must never escape `Nest.Sandbox`.

  The space dir is bound at `/tmp`, so agents only ever see
  `/tmp/<agent>/...`. The host backing path
  (`/tmp/nest-<ospid>/space-<id>/<agent>/...`) is an implementation detail of
  `Nest.Sandbox`. These tests pin that stat/glob/read resolve the sandbox
  spelling, that the `/tmp` bind source is exactly the scratch root
  `Nest.Sandbox.Paths` derives, that no host spelling leaks into a result or a
  pointer, and that read/stat/glob execute inside bwrap rather than against the
  host.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Sandbox

  setup do
    unique = System.unique_integer([:positive])

    # A workspace outside /tmp, so the space bind does not shadow it.
    workspace = Path.join([File.cwd!(), "_build", "tmp", "nest_host_path_ws_#{unique}"])
    File.mkdir_p!(workspace)

    root = Path.join(System.tmp_dir!(), "nest_host_path_#{unique}")
    agent = "agent-#{unique}"
    tmp_path = Path.join([root, "space-1", agent])
    File.mkdir_p!(tmp_path)

    on_exit(fn ->
      if String.contains?(workspace, "nest_host_path_ws"), do: File.rm_rf!(workspace)
      if String.contains?(root, "nest_host_path"), do: File.rm_rf(root)
    end)

    %{
      workspace: workspace,
      root: root,
      agent: agent,
      tmp_path: tmp_path,
      caps: Sandbox.default_caps()
    }
  end

  test "the /tmp bind source matches the translation root, and stat/glob/read resolve it", ctx do
    File.write!(Path.join(ctx.tmp_path, "report.txt"), "hello")
    sandbox_file = "/tmp/#{ctx.agent}/report.txt"

    # The bind source `Sandbox.build/3` emits for `/tmp` is exactly the scratch
    # root `Nest.Sandbox.Paths` derives — so the bind layout and the reported
    # spelling cannot drift apart.
    {:ok, args} = Sandbox.build(ctx.caps, ctx.workspace, ctx.tmp_path)
    assert bind_source_for(args, "/tmp") == Nest.FSPath.canonical(Path.dirname(ctx.tmp_path))

    # glob returns the sandbox spelling only.
    assert {:ok, [^sandbox_file]} =
             Sandbox.glob("/tmp/#{ctx.agent}/*.txt", ctx.caps, ctx.workspace, ctx.tmp_path)

    assert {:ok, %{size: 5}} =
             Sandbox.stat(sandbox_file, ctx.caps, ctx.workspace, ctx.tmp_path)

    assert {:ok, "hello"} =
             Sandbox.read(sandbox_file, ctx.caps, ctx.workspace, ctx.tmp_path)
  end

  test "glob never returns the host spelling", ctx do
    File.write!(Path.join(ctx.tmp_path, "a.txt"), "x")

    assert {:ok, files} =
             Sandbox.glob("/tmp/#{ctx.agent}/*", ctx.caps, ctx.workspace, ctx.tmp_path)

    assert files == ["/tmp/#{ctx.agent}/a.txt"]
    refute Enum.any?(files, &String.contains?(&1, ctx.tmp_path))
    refute Enum.any?(files, &String.contains?(&1, ctx.root))
  end

  test "Overflow offload pointers use the sandbox spelling", ctx do
    path = Overflow.write("body", %{tmp_path: ctx.tmp_path}, "probe", "txt")

    assert path =~ "/tmp/#{ctx.agent}/"
    refute path =~ ctx.tmp_path
    # The bytes really landed at the host backing path.
    assert File.read!(Path.join(ctx.tmp_path, Path.basename(path))) == "body"
  end

  # ---- the review's "configurations": host-vs-bwrap disagreements ----

  test "a symlink to /tmp inside the scratch dir resolves to the scratch root, not the host",
       ctx do
    # A symlink to `/tmp` in the agent's scratch dir. Inside the sandbox `/tmp`
    # is the scratch bind, so following it must list the scratch root (the
    # space dir); the host `/tmp` must never appear.
    File.ln_s!("/tmp", Path.join(ctx.tmp_path, "t"))
    File.write!(Path.join([ctx.root, "space-1", "shared.txt"]), "scratch")

    assert {:ok, files} =
             Sandbox.glob("/tmp/#{ctx.agent}/t/*", ctx.caps, ctx.workspace, ctx.tmp_path)

    assert "/tmp/#{ctx.agent}/t/shared.txt" in files
    refute Enum.any?(files, &String.contains?(&1, ctx.root))
  end

  test "a workspace at or under /tmp is rejected for stat, read, and glob alike", ctx do
    ws = Path.join(System.tmp_dir!(), "nest_shadowed_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    target = Path.join(ws, "f.txt")
    assert {:error, _} = Sandbox.stat(target, ctx.caps, ws, ctx.tmp_path)
    assert {:error, _} = Sandbox.read(target, ctx.caps, ws, ctx.tmp_path)
    assert {:error, _} = Sandbox.glob(Path.join(ws, "*"), ctx.caps, ws, ctx.tmp_path)
  end

  test "a project tmp mount with an absent out-of-workspace destination fails every op", ctx do
    source = Path.join(ctx.root, "project-src")
    mount = %{"dest" => "/absent-dir/mnt", "mode" => "tmp", "create" => false, "source" => source}
    caps = put_in(ctx.caps, ["fs", "project"], [mount])

    assert {:error, _} = Sandbox.stat("/etc/hostname", caps, ctx.workspace, ctx.tmp_path)
    assert {:error, _} = Sandbox.glob("/etc/*", caps, ctx.workspace, ctx.tmp_path)

    # A bwrap setup failure is the unexpected case, so `read` logs it rather
    # than failing silently; capture the warning so it doesn't escape.
    log =
      capture_log(fn ->
        assert {:error, _} = Sandbox.read("/etc/hostname", caps, ctx.workspace, ctx.tmp_path)
      end)

    assert log =~ "Nest.Sandbox.read: failed to read"
  end

  test "a masked .nest is a char device for stat; reading it is denied", ctx do
    nest = Path.join(ctx.workspace, ".nest")
    caps = put_in(ctx.caps, ["fs", "protected"], [%{"path" => nest, "source" => "/dev/null"}])

    # `--ro-bind` mounts with `nodev`, so the masked char device is unusable:
    # stat sees a device, but opening it is denied (not a silent empty read).
    assert {:ok, %File.Stat{type: :device}} =
             Sandbox.stat(nest, caps, ctx.workspace, ctx.tmp_path)

    assert {:error, :read_permission_denied} =
             Sandbox.read(nest, caps, ctx.workspace, ctx.tmp_path)
  end

  # The sandbox's filesystem view is bwrap's view: `read`, `stat`, and `glob`
  # must execute inside bwrap, never against the host. A source scan is a weak
  # guard (it cannot see `apply/3`, an aliased `File`, `System.cmd`, or
  # `Port.open`), so this checks the AST for the specific host-read APIs a
  # fast path would use, rather than a substring a review already defeated by
  # spelling the call differently.
  @sandbox_sources [
    "lib/nest/sandbox.ex",
    "lib/nest/sandbox/paths.ex",
    "lib/nest/tools/shell_cmd.ex"
  ]

  # Host filesystem reads/stats/opens that would bypass bwrap. `File.dir?`,
  # `File.exists?`, `File.rm`, `File.mkdir_p!`, `File.write!` (staging) and the
  # `Paths` string helpers stay allowed.
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

  test "read/stat/glob execute inside bwrap, not against the host (AST guard)" do
    for path <- @sandbox_sources do
      ast = path |> File.read!() |> Code.string_to_quoted!()
      offenders = host_read_calls(ast)

      assert offenders == [],
             "#{path} must not use host filesystem reads/stats; found: #{inspect(offenders)}"
    end
  end

  defp host_read_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, host_read_call(node, acc)}
      end)

    Enum.reverse(calls)
  end

  defp host_read_call({{:., meta, [mod, fun]}, _call_meta, _args}, acc) do
    if {module_of(mod), fun} in @host_read_calls do
      [{module_of(mod), fun, line_of(meta)} | acc]
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

  defp line_of(meta), do: Keyword.get(meta, :line)

  defp bind_source_for(args, dest) do
    args
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      ["--bind", source, ^dest] -> source
      _ -> nil
    end)
  end
end
