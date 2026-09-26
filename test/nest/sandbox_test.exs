defmodule Nest.SandboxTest do
  use ExUnit.Case, async: true

  alias Nest.Hardware
  alias Nest.Sandbox

  setup do
    dir = Path.join(System.tmp_dir!(), "nest_sandbox_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
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
    test "produces args for the build profile (workspace + /tmp writable)" do
      {:ok, args} = Sandbox.build_default("/workspace", "/tmp/agent-1")
      assert "--unshare-all" in args
      assert "--unshare-net" in args
      assert "--ro-bind" in args
      assert "--bind" in args
      assert "--dev" in args

      # Workspace is bound RW because the default caps include :workspace.
      workspace_idx = Enum.find_index(args, &(&1 == "/workspace"))
      assert workspace_idx != nil
      assert Enum.at(args, workspace_idx - 1) == "--bind"
      assert Enum.at(args, workspace_idx + 1) == "/workspace"
    end

    test "includes --bind tmp_path /tmp when tmp_path is provided" do
      {:ok, args} = Sandbox.build_default("/workspace", "/tmp/foo")
      assert "--bind" in args
      assert "/tmp/foo" in args
    end

    test "does not include --bind tmp_path /tmp when tmp_path is nil" do
      {:ok, args} = Sandbox.build_default("/workspace", nil)
      # /tmp appears nowhere in args when there's no tmp_path to bind
      refute "/tmp" in args
    end
  end

  describe "build/3 with net caps" do
    test "net=true includes --share-net and omits --unshare-net" do
      caps = build_caps(net: true, write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      assert "--share-net" in args
      refute "--unshare-net" in args
    end

    test "net=false includes --unshare-net" do
      caps = build_caps(net: false, write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      assert "--unshare-net" in args
    end
  end

  describe "build/3 with fs.read caps" do
    test "read=['/'] includes --ro-bind / /" do
      caps = build_caps(read: ["/"], write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      assert "--ro-bind" in args
      assert "/" in args
    end

    test "read=[] returns an error (bwrap needs /bin/sh)" do
      caps = build_caps(read: [], write: [":workspace"])
      assert {:error, msg} = Sandbox.build(caps, "/workspace", nil)
      assert msg =~ "caps.fs.read must include"
    end
  end

  describe "build/3 with fs.write caps" do
    test "write=[] (no extras) does NOT bind the workspace" do
      # Plan mode: workspace stays read-only via the / ro-bind.
      caps = build_caps(write: [])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)

      # No --bind at all (workspace not bound, no /tmp bind, no extras).
      refute "--bind" in args
    end

    test "write=[\":workspace\"] binds the workspace read-write" do
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/Users/me/proj", nil)

      # The workspace is bound at its actual path.
      workspace_idx = Enum.find_index(args, &(&1 == "/Users/me/proj"))
      assert workspace_idx != nil
      assert Enum.at(args, workspace_idx - 1) == "--bind"
      assert Enum.at(args, workspace_idx + 1) == "/Users/me/proj"
    end

    test ~s(write=[":workspace", "/tmp"] binds workspace + tmp via tmp_path) do
      caps = build_caps(write: ["/tmp", ":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", "/tmp/agent-1")

      # Two --bind directives: workspace and tmp
      assert Enum.count(args, &(&1 == "--bind")) == 2
      # The /tmp in args is the tmp_path bind (NOT a caps-derived bind)
      tmp_indices = args |> Enum.with_index() |> Enum.filter(&match?({"/tmp", _}, &1))
      assert length(tmp_indices) == 1
      {_, idx} = hd(tmp_indices)
      assert Enum.at(args, idx - 1) == "/tmp/agent-1"
    end

    test "write=[\"/some/extra\"] binds the extra path, NOT the workspace" do
      caps = build_caps(write: ["/some/extra"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)

      # /some/extra is bound
      assert Enum.count(args, &(&1 == "--bind")) == 1
      # Workspace path does NOT appear as a --bind target. (It does
      # appear once more as the --chdir argument, which is fine.)
      bind_count =
        args
        |> Enum.with_index()
        |> Enum.count(fn
          {"/workspace", i} -> Enum.at(args, i - 1) == "--bind"
          _ -> false
        end)

      assert bind_count == 0
    end

    test "write=[\"/tmp\"] does not produce a redundant /tmp --bind" do
      # The /tmp symbolic entry is resolved by append_tmp_bind/2; the
      # write list entry should be rejected to avoid a double bind.
      caps = build_caps(write: ["/tmp"])
      {:ok, args} = Sandbox.build(caps, "/workspace", "/tmp/agent-1")

      # Only the tmp_path bind; no extra --bind /tmp /tmp
      assert Enum.count(args, &(&1 == "--bind")) == 1
    end

    test "write includes the literal workspace_path: no double bind" do
      caps = build_caps(write: ["/workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      # The literal /workspace matches the rejection list (it equals
      # workspace_path), so no --bind is produced.
      refute "--bind" in args
    end
  end

  describe "build/3 tmp_path" do
    test "tmp_path=nil produces no /tmp bind" do
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
      refute "/tmp" in args
    end

    test "tmp_path provided produces --bind tmp_path /tmp" do
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", "/tmp/agent-1")
      tmp_indices = args |> Enum.with_index() |> Enum.filter(&match?({"/tmp", _}, &1))

      assert length(tmp_indices) == 1
      {_, idx} = hd(tmp_indices)
      assert Enum.at(args, idx - 2) == "--bind"
      assert Enum.at(args, idx - 1) == "/tmp/agent-1"
    end
  end

  describe "build/5 HPU passthrough" do
    test "binds host /dev and the Habana log dir read-write when HPUs are present" do
      caps = build_caps(write: [":workspace"])
      log_dir = Hardware.habana_log_dir()
      {:ok, args} = Sandbox.build(caps, "/workspace", nil, "/workspace", ["/dev/accel"])

      # No fresh devtmpfs; the host /dev is bound so accelerator nodes
      # are present and usable.
      refute "--dev" in args
      assert Enum.chunk_every(args, 3, 1) |> Enum.member?(["--dev-bind", "/dev", "/dev"])

      # The Habana log dir is overlaid read-write after the root ro-bind.
      assert Enum.chunk_every(args, 3, 1) |> Enum.member?(["--bind", log_dir, log_dir])
    end

    test "uses a fresh --dev devtmpfs and no Habana bind without HPUs" do
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil, "/workspace", [])

      assert "--dev" in args
      refute "--dev-bind" in args
      refute Hardware.habana_log_dir() in args
    end
  end

  describe "arg ordering (regression)" do
    test "--dev /dev and --proc /proc appear AFTER --ro-bind / /" do
      # The / ro-bind must come before --dev so the devtmpfs overlays the
      # read-only bind (not the other way around), and before --proc so
      # the freshly-mounted /proc does NOT inherit the parent's
      # read-only flag. The latter bit is the bwrap flag-order bug that
      # made /proc/self/<pid>/oom_score_adj (and friends) read-only
      # inside the sandbox. See scripts/probe-bwrap-flags.sh for the
      # probe that exposed it.
      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, "/workspace", nil)
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

  describe "rule helpers (single source of truth)" do
    test "readable_roots canonicalizes the read list" do
      assert Sandbox.readable_roots(build_caps(read: ["/"])) == ["/"]
    end

    test "writable_roots includes canonical workspace + extras, not /tmp" do
      caps = build_caps(write: [":workspace", "/tmp", "/data"])
      assert Sandbox.writable_roots(caps, "/workspace") == ["/workspace", "/data"]
    end

    test "writable_roots omits the workspace when :workspace is absent" do
      assert Sandbox.writable_roots(build_caps(write: ["/data"]), "/workspace") == ["/data"]
    end

    test "read_allowed? is true for any path under read='/'", %{tmp: dir} do
      assert Sandbox.read_allowed?(Path.join(dir, "x.txt"), build_caps())
    end

    test "write_allowed? honors the :workspace marker", %{tmp: dir} do
      assert Sandbox.write_allowed?(
               Path.join(dir, "x.txt"),
               build_caps(write: [":workspace"]),
               dir
             )

      refute Sandbox.write_allowed?(Path.join(dir, "x.txt"), build_caps(write: []), dir)
    end

    test "write_allowed? resolves symlinks before the containment check", %{tmp: dir} do
      target = Path.join(dir, "real")
      File.mkdir_p!(target)
      link = Path.join(dir, "link")
      File.ln_s!(target, link)

      in_link = Path.join(link, "x.txt")
      assert Sandbox.write_allowed?(in_link, build_caps(write: [":workspace"]), link)
    end
  end

  describe "equivalence (binds == rule helpers)" do
    test "the --bind/--ro-bind mounts are derived from writable/readable roots" do
      caps = build_caps(write: [":workspace", "/tmp", "/data"])
      {:ok, args} = Sandbox.build(caps, "/workspace", "/tmp/agent-1")

      {ro_targets, bind_targets} = collect_bind_targets(args)

      assert ro_targets == Sandbox.readable_roots(caps)
      # tmp is bound at /tmp (not a host writable root); the rest match.
      assert bind_targets -- ["/tmp"] == Sandbox.writable_roots(caps, "/workspace")
    end
  end

  describe "symlink workspace (canonical bind, user chdir)" do
    test "binds the canonical path but chdirs to the user path", %{tmp: dir} do
      real = Path.join(dir, "real")
      File.mkdir_p!(real)
      link = Path.join(dir, "link")
      File.ln_s!(real, link)

      caps = build_caps(write: [":workspace"])
      {:ok, args} = Sandbox.build(caps, link, nil)

      # Workspace is bound at its canonical (symlink-resolved) path.
      assert ["--bind", src, dst] = after_flag(args, "--bind", link)
      assert src == dst
      assert src == real

      # But --chdir targets the user-provided symlinked path.
      assert ["--chdir", ^link] = after_flag(args, "--chdir", link)
    end
  end

  describe "validate_caps/1" do
    test "valid caps return :ok" do
      assert :ok = Sandbox.validate_caps(build_caps())
    end

    test "valid caps with :workspace and /tmp in write list" do
      assert :ok =
               Sandbox.validate_caps(build_caps(write: ["/tmp", ":workspace"]))
    end

    test "missing net" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "fs" => %{"read" => ["/"], "write" => []}
               })

      assert msg =~ "caps.net is required"
    end

    test "missing fs" do
      assert {:error, msg} = Sandbox.validate_caps(%{"net" => true})
      assert msg =~ "caps.fs is required"
    end

    test "fs.read not a list" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "net" => true,
                 "fs" => %{"read" => "/", "write" => []}
               })

      assert msg =~ "caps.fs.read must be a list"
    end

    test "fs.write not a list" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "net" => true,
                 "fs" => %{"read" => ["/"], "write" => nil}
               })

      assert msg =~ "caps.fs.write must be a list"
    end

    test "fs not a map" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{"net" => true, "fs" => []})

      assert msg =~ "caps.fs must be a map"
    end

    test "read entries not all strings" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "net" => true,
                 "fs" => %{"read" => ["/", 42], "write" => []}
               })

      assert msg =~ "caps.fs.read entries must be strings"
    end

    test "write entries not all strings" do
      assert {:error, msg} =
               Sandbox.validate_caps(%{
                 "net" => true,
                 "fs" => %{"read" => ["/"], "write" => ["/foo", :bar]}
               })

      assert msg =~ "caps.fs.write entries must be strings"
    end

    test "non-map caps" do
      assert {:error, msg} = Sandbox.validate_caps("not a map")
      assert msg =~ "invalid caps"
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

    test "single star matches within one segment, sorted", %{root: root} do
      caps = build_caps(read: ["/"])
      pattern = Path.join(root, "sub/*.txt")
      expected = [Path.join(root, "sub/a.txt"), Path.join(root, "sub/b.txt")]
      assert {:ok, ^expected} = Sandbox.glob(pattern, caps, nil)
    end

    test "star matches names with a dot in them", %{root: root} do
      caps = build_caps(read: ["/"])
      pattern = Path.join(root, "sub/*.*")

      expected = [
        Path.join(root, "sub/a.txt"),
        Path.join(root, "sub/b.txt"),
        Path.join(root, "sub/c.md")
      ]

      assert {:ok, ^expected} = Sandbox.glob(pattern, caps, nil)
    end

    test "double star crosses directory boundaries (zero-or-more segments)", %{
      root: root
    } do
      caps = build_caps(read: ["/"])
      pattern = Path.join(root, "**/c.txt")
      expected = [Path.join(root, "deep/c.txt"), Path.join(root, "deep/x/c.txt")]

      assert {:ok, ^expected} = Sandbox.glob(pattern, caps, nil)
    end

    test "a literal path with no metacharacters matches exactly", %{root: root} do
      caps = build_caps(read: ["/"])
      file = Path.join(root, "sub/a.txt")
      assert {:ok, [^file]} = Sandbox.glob(file, caps, nil)
    end

    test "a non-matching pattern returns an empty list", %{root: root} do
      caps = build_caps(read: ["/"])
      pattern = Path.join(root, "sub/*.xyz")
      assert {:ok, []} = Sandbox.glob(pattern, caps, nil)
    end

    test "a pattern rooted at a nonexistent directory matches nothing", %{root: root} do
      caps = build_caps(read: ["/"])
      pattern = Path.join(root, "missing/*.txt")
      assert {:ok, []} = Sandbox.glob(pattern, caps, nil)
    end

    test "a relative pattern is resolved against the workspace", %{root: root} do
      caps = build_caps(read: ["/"])
      expected = [Path.join(root, "sub/a.txt"), Path.join(root, "sub/b.txt")]
      assert {:ok, ^expected} = Sandbox.glob("sub/*.txt", caps, root)
    end

    test "a relative pattern with no workspace is an error" do
      caps = build_caps(read: ["/"])
      assert {:error, msg} = Sandbox.glob("sub/*.txt", caps, nil)
      assert msg =~ "No workspace configured"
    end

    test "matches are filtered to files readable under the caps", %{root: root} do
      # Read only the `sub` subtree: files under `deep/` are matched by
      # the walk but dropped by the read-authorization filter.
      caps = build_caps(read: [Path.join(root, "sub")])
      expected = [Path.join(root, "sub/a.txt"), Path.join(root, "sub/b.txt")]
      assert {:ok, ^expected} = Sandbox.glob("**/*.txt", caps, root)
    end

    test "an over-broad expansion is rejected with :glob_too_broad", %{root: root} do
      caps = build_caps(read: ["/"])
      broad = Path.join(root, "broad")
      File.mkdir_p!(broad)

      for i <- 0..9 do
        File.write!(Path.join(broad, "f#{i}.txt"), "x")
      end

      pattern = Path.join(broad, "*.txt")
      assert {:error, :glob_too_broad} = Sandbox.glob(pattern, caps, nil, limit: 5)
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

  # Collect the destination paths of every --ro-bind and --bind
  # directive in the arg list, in order, ignoring flags with their own
  # arguments (--chdir/--dev/--proc) and bare flags.
  defp collect_bind_targets(args), do: do_collect(args, [], [])

  defp do_collect([], ro, bind), do: {Enum.reverse(ro), Enum.reverse(bind)}

  defp do_collect(["--ro-bind", _src, dst | rest], ro, bind),
    do: do_collect(rest, [dst | ro], bind)

  defp do_collect(["--bind", _src, dst | rest], ro, bind), do: do_collect(rest, ro, [dst | bind])
  defp do_collect(["--chdir", _ | rest], ro, bind), do: do_collect(rest, ro, bind)
  defp do_collect(["--dev", _ | rest], ro, bind), do: do_collect(rest, ro, bind)
  defp do_collect(["--proc", _ | rest], ro, bind), do: do_collect(rest, ro, bind)
  defp do_collect(["--share-net" | rest], ro, bind), do: do_collect(rest, ro, bind)
  defp do_collect(["--unshare-net" | rest], ro, bind), do: do_collect(rest, ro, bind)
  defp do_collect([_ | rest], ro, bind), do: do_collect(rest, ro, bind)

  # The 2- or 3-arg directive starting at the first occurrence of
  # `flag` in `args`, or [] when absent.
  defp after_flag(args, flag, _path) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> []
      idx -> Enum.slice(args, idx, 3)
    end
  end
end
