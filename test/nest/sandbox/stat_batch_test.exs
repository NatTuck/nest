defmodule Nest.Sandbox.StatBatchTest do
  @moduledoc """
  `Nest.Sandbox.StatBatch.stat_many/3` (issue #48): one `stat` invocation per
  chunk of paths, with per-path failure attribution, so the BatchSizer
  preflight does not spend one bwrap spawn per `file-read` call.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.StatBatch
  alias Nest.Tools.ShellCmd

  setup :verify_on_exit!

  setup do
    # `System.unique_integer/1` restarts with every BEAM, so a directory left by
    # an *interrupted* run collides with this run's first workspace — and one of
    # these fixtures leaves a mode-`000` directory that `rm_rf!` cannot walk, so
    # the next run's `mkdir_p!` fails. The OS pid makes a leftover unreachable.
    unique = "#{System.pid()}-#{System.unique_integer([:positive])}"
    workspace = Path.join([File.cwd!(), "_build", "tmp", "nest_stat_batch_ws_#{unique}"])
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf!(workspace) end)

    %{workspace: workspace, caps: Sandbox.default_caps()}
  end

  test "reports the size of every path from one invocation", ctx do
    paths =
      for name <- ~w(a.txt b.txt c.txt) do
        path = Path.join(ctx.workspace, name)
        File.write!(path, String.duplicate("x", 10))
        path
      end

    assert StatBatch.stat_many(paths, ctx.caps, Mounts.new(ctx.workspace, nil)) ==
             Map.new(paths, &{&1, {:ok, 10}})
  end

  test "reports the path the batch rejected as an error, the rest as sizes", ctx do
    present = Path.join(ctx.workspace, "present.txt")
    missing = Path.join(ctx.workspace, "missing.txt")
    File.write!(present, String.duplicate("x", 7))

    assert StatBatch.stat_many([present, missing], ctx.caps, Mounts.new(ctx.workspace, nil)) ==
             %{present => {:ok, 7}, missing => {:error, :enoent}}
  end

  test "re-stats only the paths the batch did not report", ctx do
    present = Path.join(ctx.workspace, "present.txt")
    missing = Path.join(ctx.workspace, "missing.txt")
    File.write!(present, String.duplicate("x", 7))

    # Exactly one per-path `stat/3`, for the absent path only.
    Mimic.expect(Sandbox, :stat, 1, fn path, _caps, _mounts ->
      assert path == missing
      {:error, :enoent}
    end)

    assert StatBatch.stat_many([present, missing], ctx.caps, Mounts.new(ctx.workspace, nil)) ==
             %{present => {:ok, 7}, missing => {:error, :enoent}}
  end

  test "a sandbox-level failure costs one spawn per chunk, not one per path", ctx do
    paths = for i <- 1..101, do: Path.join(ctx.workspace, "f#{i}.txt")

    # 101 paths -> two chunks (100 + 1) -> two invocations, each producing no
    # stdout at all, so the whole chunk shares one classified reason.
    Mimic.expect(ShellCmd, :execute_raw, 2, fn _cmd, _mounts, _caps ->
      {:ok, 1, "", "bwrap: Can't find source path /x: No such file or directory"}
    end)

    Mimic.reject(Sandbox, :stat, 3)

    log =
      capture_log(fn ->
        assert StatBatch.stat_many(paths, ctx.caps, Mounts.new(ctx.workspace, nil)) ==
                 Map.new(paths, &{&1, {:error, :sandbox_setup_failed}})
      end)

    # One line per chunk, not one per path — and the line stands for the whole
    # chunk rather than naming one path as if it were the only failure. The
    # first chunk carries 100 of the 101 paths.
    # `capture_log` is global, so this asserts inclusion only (SMELLS.md).
    assert log =~ "Nest.Sandbox.stat: sandbox_setup_failed"
    assert log =~ "(+99 more)"
  end

  test "stats a path containing a newline individually", ctx do
    plain = Path.join(ctx.workspace, "plain.txt")
    newline = Path.join(ctx.workspace, "with\nnewline.txt")
    File.write!(plain, String.duplicate("x", 5))

    # Line-framed batch output cannot carry it, so it goes through `stat/3`.
    Mimic.expect(Sandbox, :stat, 1, fn path, _caps, _mounts ->
      assert path == newline
      {:error, :enoent}
    end)

    assert StatBatch.stat_many([plain, newline], ctx.caps, Mounts.new(ctx.workspace, nil)) ==
             %{plain => {:ok, 5}, newline => {:error, :enoent}}
  end

  test "skips the batched invocation entirely when every path has a newline", ctx do
    paths = [Path.join(ctx.workspace, "a\nb"), Path.join(ctx.workspace, "c\nd")]

    # No operand can ride the batch, so nothing is spawned for it.
    Mimic.reject(ShellCmd, :execute_raw, 3)

    Mimic.expect(Sandbox, :stat, 2, fn path, _caps, _mounts ->
      assert path in paths
      {:error, :enoent}
    end)

    assert StatBatch.stat_many(paths, ctx.caps, Mounts.new(ctx.workspace, nil)) ==
             Map.new(paths, &{&1, {:error, :enoent}})
  end

  test "re-stats a path whose line the batch output did not yield", ctx do
    path = Path.join(ctx.workspace, "a.txt")

    # `stat` claimed success but printed nothing parseable, so the contract
    # ("an entry for every path") is kept by the per-path fallback.
    Mimic.expect(ShellCmd, :execute_raw, 1, fn _cmd, _mounts, _caps ->
      {:ok, 0, "not a stat line\n", ""}
    end)

    Mimic.expect(Sandbox, :stat, 1, fn p, _caps, _mounts ->
      assert p == path
      {:ok, %File.Stat{size: 3}}
    end)

    assert StatBatch.stat_many([path], ctx.caps, Mounts.new(ctx.workspace, nil)) == %{
             path => {:ok, 3}
           }
  end

  test "the batched stat agrees with the sandbox view, not the host view", ctx do
    # The host sees a regular file; the sandbox masks it with `/dev/null`, a
    # char device of size 0. Reporting the sandbox's view (not the host's byte
    # count) is the proof the batched command runs inside bwrap.
    nest = Path.join(ctx.workspace, ".nest")
    File.write!(nest, "host bytes")
    assert File.stat!(nest).size == 10

    caps = put_in(ctx.caps, ["fs", "protected"], [%{"path" => nest, "source" => "/dev/null"}])

    assert StatBatch.stat_many([nest], caps, Mounts.new(ctx.workspace, nil)) == %{
             nest => {:ok, 0}
           }
  end

  test "returns an error for every path when the sandbox cannot run", ctx do
    paths = [Path.join(ctx.workspace, "a.txt"), Path.join(ctx.workspace, "b.txt")]

    Mimic.expect(ShellCmd, :execute_raw, 1, fn _cmd, _mounts, _caps ->
      {:error, "No workspace configured for this agent"}
    end)

    Mimic.reject(Sandbox, :stat, 3)

    assert StatBatch.stat_many(paths, ctx.caps, Mounts.new(ctx.workspace, nil)) ==
             Map.new(paths, &{&1, {:error, "No workspace configured for this agent"}})
  end

  describe "equivalence with per-path stat/4" do
    # The batch's entire job is to answer what `stat/3` would have answered,
    # path for path. These are the awkward paths: the framing trick the module
    # doc advertises (`%n` last, so a `|` in a path cannot break the line) has
    # no other test, and a symlink / a directory / a name that is not valid
    # UTF-8 each exercise a different part of the parse and the fallback.
    test "agrees on pipes, symlinks, directories and non-UTF8 names", ctx do
      pipe = Path.join(ctx.workspace, "a|b|c.txt")
      File.write!(pipe, String.duplicate("x", 11))

      target = Path.join(ctx.workspace, "target.txt")
      File.write!(target, String.duplicate("y", 13))
      link = Path.join(ctx.workspace, "link.txt")
      File.ln_s!(target, link)

      dir = Path.join(ctx.workspace, "subdir")
      File.mkdir_p!(dir)

      # Byte-wise concatenation: `Path.join/2` is not asked to validate it.
      non_utf8 = ctx.workspace <> "/bad-" <> <<0xFF, 0xFE>> <> ".txt"
      File.write!(non_utf8, String.duplicate("z", 17))

      paths = [pipe, link, dir, non_utf8]

      # The `|` path reports its real size, not a size parsed out of the path:
      # this is the assertion the framing claim in the moduledoc was missing.
      assert StatBatch.stat_many([pipe], ctx.caps, Mounts.new(ctx.workspace, nil)) ==
               %{pipe => {:ok, 11}}

      assert StatBatch.stat_many(paths, ctx.caps, Mounts.new(ctx.workspace, nil)) ==
               per_path_stat(paths, ctx.caps, ctx.workspace)
    end

    test "agrees on a path the sandbox denies", ctx do
      denied_dir = Path.join(ctx.workspace, "denied")
      File.mkdir_p!(denied_dir)
      denied = Path.join(denied_dir, "secret.txt")
      File.write!(denied, "s")
      File.chmod!(denied_dir, 0o000)

      # `on_exit` runs LIFO, so this restores the mode before the setup's
      # `rm_rf!` walks the workspace.
      on_exit(fn -> File.chmod!(denied_dir, 0o755) end)

      # Pin the fixture itself: if the sandbox could read through the mode the
      # equivalence below would hold vacuously (both sides `{:ok, _}`).
      assert per_path_stat([denied], ctx.caps, ctx.workspace) ==
               %{denied => {:error, :read_permission_denied}}

      assert StatBatch.stat_many([denied], ctx.caps, Mounts.new(ctx.workspace, nil)) ==
               per_path_stat([denied], ctx.caps, ctx.workspace)
    end
  end

  # The per-path answer `Sandbox.stat/3` gives, in `stat_many/3`'s shape
  # (`{:ok, size}` rather than a `%File.Stat{}`), so the two can be compared
  # byte for byte — `:ok`/`:error` shape and reason included.
  defp per_path_stat(paths, caps, workspace) do
    Map.new(paths, fn path ->
      case Sandbox.stat(path, caps, Mounts.new(workspace, nil)) do
        {:ok, %File.Stat{size: size}} -> {path, {:ok, size}}
        {:error, reason} -> {path, {:error, reason}}
      end
    end)
  end
end
