defmodule Nest.SandboxHostPathTest do
  @moduledoc """
  Guard: the host scratch spelling must never escape `Nest.Sandbox`.

  The space dir is bound at `/tmp`, so agents only ever see
  `/tmp/<agent>/...`. The host backing path
  (`/tmp/nest-<ospid>/space-<id>/<agent>/...`) is an implementation detail of
  `Nest.Sandbox`. These tests pin that stat/glob/read resolve the sandbox
  spelling, that the `/tmp` bind source is exactly the scratch root the
  translation uses, and that no host spelling leaks into a result, a pointer,
  or a source read.
  """
  use ExUnit.Case, async: true

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
    # root the stat/glob translation derives from — so a bind-layout change and
    # the translation cannot drift apart.
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

  test "Sandbox.read does not touch the host filesystem (source guard)" do
    source = File.read!("lib/nest/sandbox.ex")

    refute source =~ "File.read(", "reads must go through bwrap, not File.read/1"
    assert source =~ "ShellCmd.execute_raw"
  end

  defp bind_source_for(args, dest) do
    args
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value(fn
      ["--bind", source, ^dest] -> source
      _ -> nil
    end)
  end
end
