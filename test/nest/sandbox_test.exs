defmodule Nest.SandboxTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Hardware
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts

  setup do
    # A workspace outside /tmp: the scratch dir is bound at /tmp, so a
    # workspace under /tmp is rejected unconditionally.
    dir =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_sandbox_test_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)

    on_exit(fn ->
      if String.contains?(dir, "nest_sandbox_test"), do: File.rm_rf(dir)
    end)

    %{tmp: dir}
  end

  describe "default_caps/0" do
    test "returns the all-writable 'build' profile" do
      assert Sandbox.default_caps() == %{
               "net" => false,
               "fs" => %{"read" => ["/"], "write" => ["/tmp", ":workspace"]}
             }
    end
  end

  describe "build_default/2" do
    test "produces args for the build profile, binding the space dir at /tmp only with a tmp_path",
         %{tmp: dir} do
      {:ok, args} = Sandbox.build_default(Mounts.new(dir, "/tmp/nest-123/space-7/agent-1"))

      assert "--unshare-all" in args
      assert "--unshare-net" in args
      assert "--ro-bind" in args
      assert "--bind" in args
      assert "--dev" in args

      # Workspace is bound RW because the default caps include :workspace.
      workspace_idx = Enum.find_index(args, &(&1 == dir))
      assert workspace_idx != nil
      assert Enum.at(args, workspace_idx - 1) == "--bind"
      assert Enum.at(args, workspace_idx + 1) == dir

      # The *space* dir (the parent of the agent's own tmp_path) is what
      # gets bound at /tmp, so every agent in the space shares one /tmp.
      idx = Enum.find_index(args, &(&1 == "/tmp/nest-123/space-7"))
      assert idx != nil
      assert Enum.at(args, idx - 1) == "--bind"
      assert Enum.at(args, idx + 1) == "/tmp"

      {:ok, no_tmp_path} = Sandbox.build_default(Mounts.new(dir, nil))
      # /tmp appears nowhere in args when there's no tmp_path to bind
      refute "/tmp" in no_tmp_path
    end
  end

  describe "build/3 with net caps" do
    test "the net cap picks --share-net or --unshare-net", %{tmp: dir} do
      {:ok, shared} =
        Sandbox.build(build_caps(net: true, write: [":workspace"]), Mounts.new(dir, nil))

      assert "--share-net" in shared
      refute "--unshare-net" in shared

      {:ok, unshared} =
        Sandbox.build(build_caps(net: false, write: [":workspace"]), Mounts.new(dir, nil))

      assert "--unshare-net" in unshared
      refute "--share-net" in unshared
    end
  end

  describe "build/3 with fs.read caps" do
    test "read=['/'] produces the root ro-bind; an empty read list is an error", %{tmp: dir} do
      {:ok, args} =
        Sandbox.build(build_caps(read: ["/"], write: [":workspace"]), Mounts.new(dir, nil))

      assert "--ro-bind" in args
      assert "/" in args

      # bwrap runs /bin/sh out of the read set, so an empty list cannot produce
      # a runnable sandbox.
      assert {:error, msg} =
               Sandbox.build(build_caps(read: [], write: [":workspace"]), Mounts.new(dir, nil))

      assert msg =~ "caps.fs.read must include"
    end
  end

  describe "build/3 with fs.write caps" do
    test "the write list decides which paths get a --bind", %{tmp: dir} do
      # No write entries at all (plan mode): the workspace stays read-only via
      # the / ro-bind, so there is no --bind anywhere.
      {:ok, no_writes} = Sandbox.build(build_caps(write: []), Mounts.new(dir, nil))
      refute "--bind" in no_writes

      # ":workspace" binds the workspace read-write at its actual path.
      {:ok, workspace_write} =
        Sandbox.build(build_caps(write: [":workspace"]), Mounts.new(dir, nil))

      workspace_idx = Enum.find_index(workspace_write, &(&1 == dir))
      assert workspace_idx != nil
      assert Enum.at(workspace_write, workspace_idx - 1) == "--bind"
      assert Enum.at(workspace_write, workspace_idx + 1) == dir

      # A literal path is bound at its own path, and the workspace is not bound
      # at all. (It does appear once more as the --chdir argument, which is
      # fine.)
      {:ok, extra} = Sandbox.build(build_caps(write: ["/some/extra"]), Mounts.new(dir, nil))
      assert Enum.count(extra, &(&1 == "--bind")) == 1

      bind_count =
        extra
        |> Enum.with_index()
        |> Enum.count(fn
          {^dir, i} -> Enum.at(extra, i - 1) == "--bind"
          _ -> false
        end)

      assert bind_count == 0

      # The literal workspace path matches the rejection list (it equals
      # workspace_path), so no --bind is produced for it either.
      {:ok, literal_workspace} = Sandbox.build(build_caps(write: [dir]), Mounts.new(dir, nil))
      refute "--bind" in literal_workspace
    end

    test "a raw /tmp write entry adds no bind of its own, while :workspace still binds", %{
      tmp: dir
    } do
      mounts = Mounts.new(dir, "/tmp/nest-123/space-7/agent-1")

      # Two --bind directives: workspace and the space dir bound at /tmp
      {:ok, both} = Sandbox.build(build_caps(write: ["/tmp", ":workspace"]), mounts)
      assert Enum.count(both, &(&1 == "--bind")) == 2

      # The /tmp in args is the space-dir bind (NOT a caps-derived bind)
      tmp_indices = both |> Enum.with_index() |> Enum.filter(&match?({"/tmp", _}, &1))
      assert length(tmp_indices) == 1
      {_, idx} = hd(tmp_indices)
      assert Enum.at(both, idx - 1) == "/tmp/nest-123/space-7"

      # The symbolic /tmp entry is resolved by the scratch bind, so the write
      # list entry is rejected to avoid a double bind: only the space-dir bind
      # is left.
      {:ok, raw_tmp} = Sandbox.build(build_caps(write: ["/tmp"]), mounts)
      assert Enum.count(raw_tmp, &(&1 == "--bind")) == 1
    end
  end

  describe "build/3 tmp_path" do
    test "the space dir is bound at /tmp only with a tmp_path, read-only unless the mode grants it",
         %{
           tmp: dir
         } do
      # No tmp_path means no /tmp bind at all.
      {:ok, no_scratch} = Sandbox.build(build_caps(write: [":workspace"]), Mounts.new(dir, nil))
      refute "/tmp" in no_scratch

      mounts = Mounts.new(dir, "/tmp/nest-123/space-7/agent-1")

      # The scratch is only writable when the mode grants the symbolic /tmp
      # write; otherwise it stays readable but read-only.
      {:ok, ro_args} = Sandbox.build(build_caps(write: [":workspace"]), mounts)
      ro_tmp = ro_args |> Enum.with_index() |> Enum.filter(&match?({"/tmp", _}, &1))
      assert length(ro_tmp) == 1
      {_, ro_idx} = hd(ro_tmp)
      assert Enum.at(ro_args, ro_idx - 2) == "--ro-bind"
      assert Enum.at(ro_args, ro_idx - 1) == "/tmp/nest-123/space-7"

      {:ok, rw_args} = Sandbox.build(build_caps(write: [":workspace", "/tmp"]), mounts)
      rw_tmp = rw_args |> Enum.with_index() |> Enum.filter(&match?({"/tmp", _}, &1))
      assert length(rw_tmp) == 1
      {_, rw_idx} = hd(rw_tmp)
      assert Enum.at(rw_args, rw_idx - 2) == "--bind"
      assert Enum.at(rw_args, rw_idx - 1) == "/tmp/nest-123/space-7"
    end
  end

  describe "build/5 HPU passthrough" do
    test "HPUs bind host /dev and the Habana log dir; without them, a fresh devtmpfs", %{
      tmp: dir
    } do
      caps = build_caps(write: [":workspace"])
      log_dir = Hardware.habana_log_dir()

      {:ok, with_hpu} = Sandbox.build(caps, Mounts.new(dir, nil), dir, ["/dev/accel"])

      # No fresh devtmpfs; the host /dev is bound so accelerator nodes
      # are present and usable.
      refute "--dev" in with_hpu
      assert Enum.chunk_every(with_hpu, 3, 1) |> Enum.member?(["--dev-bind", "/dev", "/dev"])

      # The Habana log dir is overlaid read-write after the root ro-bind.
      assert Enum.chunk_every(with_hpu, 3, 1) |> Enum.member?(["--bind", log_dir, log_dir])

      {:ok, without_hpu} = Sandbox.build(caps, Mounts.new(dir, nil), dir, [])

      assert "--dev" in without_hpu
      refute "--dev-bind" in without_hpu
      refute log_dir in without_hpu
    end
  end

  describe "arg ordering (regression)" do
    test "--dev /dev and --proc /proc appear AFTER --ro-bind / /", %{tmp: dir} do
      # The / ro-bind must come before --dev so the devtmpfs overlays the
      # read-only bind (not the other way around), and before --proc so
      # the freshly-mounted /proc does NOT inherit the parent's
      # read-only flag. The latter bit is the bwrap flag-order bug that
      # made /proc/self/<pid>/oom_score_adj (and friends) read-only
      # inside the sandbox. See scripts/probe-bwrap-flags.sh for the
      # probe that exposed it.
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, Mounts.new(dir, nil))
      ro_bind_idx = Enum.find_index(args, &(&1 == "--ro-bind"))
      dev_idx = Enum.find_index(args, &(&1 == "--dev"))
      proc_idx = Enum.find_index(args, &(&1 == "--proc"))

      assert ro_bind_idx < dev_idx,
             "expected --ro-bind before --dev (bwrap arg order regression)"

      assert ro_bind_idx < proc_idx,
             "expected --ro-bind before --proc (bwrap arg order regression: " <>
               "--proc before --ro-bind makes /proc/self read-only inside the sandbox)"
    end
  end

  describe "readable_roots/1" do
    test "canonicalizes the read list" do
      assert Sandbox.readable_roots(build_caps(read: ["/"])) == ["/"]
    end
  end

  describe "workspace validation" do
    test "rejects a workspace at or under the scratch bind or one that does not exist, and chdirs to the scratch root with no workspace",
         %{
           tmp: dir
         } do
      caps = build_caps(write: [":workspace", "/tmp"])

      assert {:error, msg} =
               Sandbox.build(caps, Mounts.new("/tmp/ws", "/tmp/nest-1/space-1/agent-1"))

      assert msg =~ "must not be at or under /tmp"

      assert {:error, _} = Sandbox.build(caps, Mounts.new("/tmp", "/tmp/nest-1/space-1/agent-1"))

      # The rejection is unconditional: no scratch bind is needed.
      assert {:error, _} = Sandbox.build(caps, Mounts.new("/tmp/ws", nil))

      # A workspace that does not exist is rejected too.
      assert {:error, msg} = Sandbox.build(caps, Mounts.new(Path.join(dir, "missing"), nil))
      assert msg =~ "does not exist"

      # `workspace_error/1` is the classification both gates above go through.
      assert :ok = Sandbox.workspace_error(nil)
      assert {:error, :workspace_under_tmp} = Sandbox.workspace_error("/tmp/ws")
      assert {:error, :workspace_missing} = Sandbox.workspace_error("/nope/does/not/exist")

      # With no workspace at all there is nothing to bind, so bwrap's cwd is the
      # scratch root.
      {:ok, args} =
        Sandbox.build(build_caps(write: ["/tmp"]), Mounts.new(nil, "/tmp/nest-1/space-1/agent-1"))

      assert ["--chdir", "/tmp" | _] = after_flag(args, "--chdir", "/tmp")
    end

    # These two stay separate even though they build the same fixture: the
    # refusal warning is logged once per path (`Nest.ConfigFile.refuse/2` dedupes
    # on `:persistent_term`), so whichever call runs first consumes it and the
    # second logs nothing. Asserting both warnings in one test is impossible.
    test "workspace_error/1 refuses a workspace whose config file is a symlink", %{tmp: dir} do
      # A symlink cannot be masked, and a mask that is merely omitted leaves the
      # path replaceable — an `act` agent could delete the link and write a
      # regular `.nest` granting host access.
      real = Path.join(dir, "real.nest")
      File.write!(real, "")
      File.ln_s!(real, Path.join(dir, ".nest"))

      log =
        capture_log(fn ->
          assert {:error, {:config_file_not_regular, path, _type}} =
                   Sandbox.workspace_error(dir)

          assert path == Path.join(dir, ".nest")
        end)

      assert log =~ "Nest cannot protect it from being rewritten"
    end

    test "build/4 refuses a workspace whose config file is a symlink", %{tmp: dir} do
      # The *final* gate: whatever reaches the sandbox is checked here, so a
      # workspace that became symlinked after it was chosen cannot be used.
      real = Path.join(dir, "real.nest")
      File.write!(real, "")
      File.ln_s!(real, Path.join(dir, ".nest"))

      log =
        capture_log(fn ->
          assert {:error, reason} = Sandbox.build(build_caps(), Mounts.new(dir, nil))
          assert reason =~ "not a regular file"
        end)

      assert log =~ "Nest cannot protect it from being rewritten"
    end
  end

  describe "symlink workspace (canonical bind, user chdir)" do
    test "binds the canonical path but chdirs to the user path", %{tmp: dir} do
      real = Path.join(dir, "real")
      File.mkdir_p!(real)
      link = Path.join(dir, "link")
      File.ln_s!(real, link)

      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, Mounts.new(link, nil))

      # Workspace is bound at its canonical (symlink-resolved) path.
      assert ["--bind", src, dst] = after_flag(args, "--bind", link)
      assert src == dst
      assert src == real

      # But --chdir targets the user-provided symlinked path.
      assert ["--chdir", ^link] = after_flag(args, "--chdir", link)
    end
  end

  describe "validate_caps/1" do
    test "valid caps return :ok, with or without :workspace and /tmp in the write list" do
      assert :ok = Sandbox.validate_caps(build_caps())

      assert :ok =
               Sandbox.validate_caps(build_caps(write: ["/tmp", ":workspace"]))
    end

    test "malformed caps are rejected with a diagnostic naming the problem" do
      # One row per way the shape can be wrong; `build_caps/1` cannot express
      # these, so each map is written out.
      for {label, caps, expected} <- [
            {"missing net", %{"fs" => %{"read" => ["/"], "write" => []}}, "caps.net is required"},
            {"missing fs", %{"net" => true}, "caps.fs is required"},
            {"fs not a map", %{"net" => true, "fs" => []}, "caps.fs must be a map"},
            {"fs.read not a list", %{"net" => true, "fs" => %{"read" => "/", "write" => []}},
             "caps.fs.read must be a list"},
            {"fs.write not a list", %{"net" => true, "fs" => %{"read" => ["/"], "write" => nil}},
             "caps.fs.write must be a list"},
            {"read entries not all strings",
             %{"net" => true, "fs" => %{"read" => ["/", 42], "write" => []}},
             "caps.fs.read entries must be strings"},
            {"write entries not all strings",
             %{"net" => true, "fs" => %{"read" => ["/"], "write" => ["/foo", :bar]}},
             "caps.fs.write entries must be strings"},
            {"non-map caps", "not a map", "invalid caps"}
          ] do
        assert {:error, msg} = Sandbox.validate_caps(caps), label
        assert msg =~ expected, label
      end
    end

    test "the project's declared docker packages are checked for shape" do
      # `Nest.ProjectConfig` validates the list where it parses `.nest`; this is
      # the check for a caps map that reached a backend another way, so the docker
      # backend never interpolates something that is not a list of strings into an
      # `apt-get install` line.
      valid = Map.put(build_caps(), "sandbox", %{"packages" => ["nodejs"]})
      assert :ok = Sandbox.validate_caps(valid)

      assert {:error, msg} =
               Sandbox.validate_caps(Map.put(build_caps(), "sandbox", "nodejs"))

      assert msg =~ "caps.sandbox must be a map"

      assert {:error, msg} =
               Sandbox.validate_caps(Map.put(build_caps(), "sandbox", %{"packages" => "nodejs"}))

      assert msg =~ "caps.sandbox.packages must be a list"

      assert {:error, msg} =
               Sandbox.validate_caps(Map.put(build_caps(), "sandbox", %{"packages" => [3]}))

      assert msg =~ "caps.sandbox.packages entries must be strings"
    end
  end

  describe "glob/4" do
    setup %{tmp: dir} do
      # Use the canonical (symlink-resolved) root: `glob/4` canonicalizes
      # its walk base, so the returned paths are canonical. Building the
      # fixture and the expectations from the same canonical root keeps
      # the assertions exact on platforms where `/tmp` is a symlink.
      root = Nest.FSPath.canonical(dir)

      File.mkdir_p!(Path.join(root, "sub"))
      File.mkdir_p!(Path.join(root, "deep/x"))
      File.mkdir_p!(Path.join(root, "other"))

      for rel <- [
            "sub/a.txt",
            "sub/b.txt",
            "sub/c.md",
            "deep/c.txt",
            "deep/x/c.txt",
            "other/secret.txt"
          ] do
        File.write!(Path.join(root, rel), "x")
      end

      %{tmp: dir, root: root}
    end

    test "star, double-star, literal and relative patterns expand to the expected paths", %{
      root: root
    } do
      caps = build_caps(read: ["/"])

      for {label, pattern, workspace, expected} <- [
            # `*` stays within one segment, and the matches come back sorted.
            {"single star", Path.join(root, "sub/*.txt"), nil,
             [Path.join(root, "sub/a.txt"), Path.join(root, "sub/b.txt")]},
            # A name with a dot in it is matched by `*` like any other name.
            {"star with dots", Path.join(root, "sub/*.*"), nil,
             [
               Path.join(root, "sub/a.txt"),
               Path.join(root, "sub/b.txt"),
               Path.join(root, "sub/c.md")
             ]},
            # `**` crosses directory boundaries (zero-or-more segments).
            {"double star", Path.join(root, "**/c.txt"), nil,
             [Path.join(root, "deep/c.txt"), Path.join(root, "deep/x/c.txt")]},
            # A literal path with no metacharacters matches exactly.
            {"literal", Path.join(root, "sub/a.txt"), nil, [Path.join(root, "sub/a.txt")]},
            # A relative pattern is resolved against the workspace.
            {"relative", "sub/*.txt", root,
             [Path.join(root, "sub/a.txt"), Path.join(root, "sub/b.txt")]}
          ] do
        assert {:ok, ^expected} = Sandbox.glob(pattern, caps, Mounts.new(workspace, nil)), label
      end
    end

    test "a pattern that matches nothing returns an empty list", %{root: root} do
      caps = build_caps(read: ["/"])

      for {label, pattern} <- [
            # The directory exists, but nothing in it has that extension.
            {"no matching name", Path.join(root, "sub/*.xyz")},
            # The directory the pattern is rooted at does not exist at all.
            {"missing base dir", Path.join(root, "missing/*.txt")}
          ] do
        assert {:ok, []} = Sandbox.glob(pattern, caps, Mounts.new(nil, nil)), label
      end
    end

    test "matches resolve through the bwrap mounts, not the host", %{root: root} do
      # Mask one matched file with /dev/null. Inside bwrap the path is a char
      # device, so the regular-file filter drops it — proof that the glob
      # resolves through the mounts rather than the host file underneath.
      masked = Path.join(root, "sub/a.txt")

      caps =
        build_caps(read: ["/"])
        |> put_in(["fs", "protected"], [%{"path" => masked, "source" => "/dev/null"}])

      pattern = Path.join(root, "**/*.txt")
      assert {:ok, files} = Sandbox.glob(pattern, caps, Mounts.new(root, nil))

      refute masked in files
      assert Path.join(root, "sub/b.txt") in files
    end

    test "a pattern that cannot be honored is refused", %{root: root} do
      caps = build_caps(read: ["/"])

      # A relative pattern has nothing to resolve against with no workspace.
      assert {:error, msg} = Sandbox.glob("sub/*.txt", caps, Mounts.new(nil, nil))
      assert msg =~ "No workspace configured"

      # A terminal `**` is refused: bash would expand the whole subtree.
      assert {:error, :glob_terminal_double_star} =
               Sandbox.glob(Path.join(root, "**"), caps, Mounts.new(root, nil))

      # More raw matches than `limit:` allows is refused rather than truncated.
      broad = Path.join(root, "broad")
      File.mkdir_p!(broad)

      for i <- 0..9 do
        File.write!(Path.join(broad, "f#{i}.txt"), "x")
      end

      assert {:error, :glob_too_broad} =
               Sandbox.glob(Path.join(broad, "*.txt"), caps, Mounts.new(nil, nil), limit: 5)
    end
  end

  # Helpers

  defp build_caps(opts \\ []) do
    %{
      "net" => Keyword.get(opts, :net, false),
      "fs" => %{
        "read" => Keyword.get(opts, :read, ["/"]),
        "write" => Keyword.get(opts, :write, [])
      }
    }
  end

  # The 2- or 3-arg directive starting at the first occurrence of
  # `flag` in `args`, or [] when absent.
  defp after_flag(args, flag, _path) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> []
      idx -> Enum.slice(args, idx, 3)
    end
  end
end
