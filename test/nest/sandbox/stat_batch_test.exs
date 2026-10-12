defmodule Nest.Sandbox.StatBatchTest do
  @moduledoc """
  `Nest.Sandbox.StatBatch.stat_many/4` (issue #48): one `stat` invocation per
  chunk of paths, with per-path failure attribution, so the BatchSizer
  preflight does not spend one bwrap spawn per `file-read` call.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Mimic

  alias Nest.Sandbox
  alias Nest.Sandbox.StatBatch
  alias Nest.Tools.ShellCmd

  setup :verify_on_exit!

  setup do
    unique = System.unique_integer([:positive])
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

    assert StatBatch.stat_many(paths, ctx.caps, ctx.workspace, nil) ==
             Map.new(paths, &{&1, {:ok, 10}})
  end

  test "reports the path the batch rejected as an error, the rest as sizes", ctx do
    present = Path.join(ctx.workspace, "present.txt")
    missing = Path.join(ctx.workspace, "missing.txt")
    File.write!(present, String.duplicate("x", 7))

    assert StatBatch.stat_many([present, missing], ctx.caps, ctx.workspace, nil) ==
             %{present => {:ok, 7}, missing => {:error, :enoent}}
  end

  test "re-stats only the paths the batch did not report", ctx do
    present = Path.join(ctx.workspace, "present.txt")
    missing = Path.join(ctx.workspace, "missing.txt")
    File.write!(present, String.duplicate("x", 7))

    # Exactly one per-path `stat/4`, for the absent path only.
    Mimic.expect(Sandbox, :stat, 1, fn path, _caps, _ws, _tmp ->
      assert path == missing
      {:error, :enoent}
    end)

    assert StatBatch.stat_many([present, missing], ctx.caps, ctx.workspace, nil) ==
             %{present => {:ok, 7}, missing => {:error, :enoent}}
  end

  test "a sandbox-level failure costs one spawn per chunk, not one per path", ctx do
    paths = for i <- 1..101, do: Path.join(ctx.workspace, "f#{i}.txt")

    # 101 paths -> two chunks (100 + 1) -> two invocations, each producing no
    # stdout at all, so the whole chunk shares one classified reason.
    Mimic.expect(ShellCmd, :execute_raw, 2, fn _cmd, _ws, _tmp, _caps ->
      {:ok, 1, "", "bwrap: Can't find source path /x: No such file or directory"}
    end)

    Mimic.reject(Sandbox, :stat, 4)

    log =
      capture_log(fn ->
        assert StatBatch.stat_many(paths, ctx.caps, ctx.workspace, nil) ==
                 Map.new(paths, &{&1, {:error, :sandbox_setup_failed}})
      end)

    # One line per chunk, not one per path. `capture_log` is global, so this
    # asserts inclusion only (SMELLS.md).
    assert log =~ "Nest.Sandbox.stat: sandbox_setup_failed"
  end

  test "stats a path containing a newline individually", ctx do
    plain = Path.join(ctx.workspace, "plain.txt")
    newline = Path.join(ctx.workspace, "with\nnewline.txt")
    File.write!(plain, String.duplicate("x", 5))

    # Line-framed batch output cannot carry it, so it goes through `stat/4`.
    Mimic.expect(Sandbox, :stat, 1, fn path, _caps, _ws, _tmp ->
      assert path == newline
      {:error, :enoent}
    end)

    assert StatBatch.stat_many([plain, newline], ctx.caps, ctx.workspace, nil) ==
             %{plain => {:ok, 5}, newline => {:error, :enoent}}
  end

  test "skips the batched invocation entirely when every path has a newline", ctx do
    paths = [Path.join(ctx.workspace, "a\nb"), Path.join(ctx.workspace, "c\nd")]

    # No operand can ride the batch, so nothing is spawned for it.
    Mimic.reject(ShellCmd, :execute_raw, 4)

    Mimic.expect(Sandbox, :stat, 2, fn path, _caps, _ws, _tmp ->
      assert path in paths
      {:error, :enoent}
    end)

    assert StatBatch.stat_many(paths, ctx.caps, ctx.workspace, nil) ==
             Map.new(paths, &{&1, {:error, :enoent}})
  end

  test "re-stats a path whose line the batch output did not yield", ctx do
    path = Path.join(ctx.workspace, "a.txt")

    # `stat` claimed success but printed nothing parseable, so the contract
    # ("an entry for every path") is kept by the per-path fallback.
    Mimic.expect(ShellCmd, :execute_raw, 1, fn _cmd, _ws, _tmp, _caps ->
      {:ok, 0, "not a stat line\n", ""}
    end)

    Mimic.expect(Sandbox, :stat, 1, fn p, _caps, _ws, _tmp ->
      assert p == path
      {:ok, %File.Stat{size: 3}}
    end)

    assert StatBatch.stat_many([path], ctx.caps, ctx.workspace, nil) == %{path => {:ok, 3}}
  end

  test "the batched stat agrees with the sandbox view, not the host view", ctx do
    # The host sees a regular file; the sandbox masks it with `/dev/null`, a
    # char device of size 0. Reporting the sandbox's view (not the host's byte
    # count) is the proof the batched command runs inside bwrap.
    nest = Path.join(ctx.workspace, ".nest")
    File.write!(nest, "host bytes")
    assert File.stat!(nest).size == 10

    caps = put_in(ctx.caps, ["fs", "protected"], [%{"path" => nest, "source" => "/dev/null"}])

    assert StatBatch.stat_many([nest], caps, ctx.workspace, nil) == %{nest => {:ok, 0}}
  end

  test "returns an error for every path when the sandbox cannot run", ctx do
    paths = [Path.join(ctx.workspace, "a.txt"), Path.join(ctx.workspace, "b.txt")]

    Mimic.expect(ShellCmd, :execute_raw, 1, fn _cmd, _ws, _tmp, _caps ->
      {:error, "No workspace configured for this agent"}
    end)

    Mimic.reject(Sandbox, :stat, 4)

    assert StatBatch.stat_many(paths, ctx.caps, ctx.workspace, nil) ==
             Map.new(paths, &{&1, {:error, "No workspace configured for this agent"}})
  end
end
