defmodule Nest.ProjectConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.ProjectConfig
  alias Nest.Sandbox.Mounts

  setup do
    dir = Path.join(System.tmp_dir!(), "nest_projcfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> if String.contains?(dir, "nest_projcfg_"), do: File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp write_nest(dir, body), do: File.write!(nest_path(dir), body)

  defp nest_path(dir), do: Path.join(dir, ".nest")

  # The two terms of the identity a stat-based key would have used. Reading them
  # the way `File.stat/2` reports them, and forcing a rewrite back onto the
  # previous value of both, is what leaves the bytes as the only thing that can
  # tell two revisions apart. `File.touch!/2` takes a posix second directly
  # (`posix_time()` is in its spec), so this needs no timezone conversion.
  defp identity_of(dir) do
    path = nest_path(dir)
    %{mtime: File.stat!(path, time: :posix).mtime, size: File.stat!(path).size}
  end

  defp caps(write \\ [":workspace"]) do
    %{"net" => false, "fs" => %{"read" => ["/"], "write" => write}}
  end

  # Each case writes a *different* body to the same `.nest`, and this expects
  # the error to be reported every time. That holds because the parse cache is
  # keyed on the bytes: a body the cache has not seen is a miss, so the parse
  # runs and logs. No cache clearing is involved — with the old mtime key, two
  # of these writes landing inside one second were indistinguishable and the
  # second case was served the first case's error.
  defp expect_error(dir, body, needle) do
    write_nest(dir, body)

    log =
      capture_log(fn ->
        assert {:error, reason} = ProjectConfig.load(dir)
        assert reason =~ needle
      end)

    assert log =~ "ignoring"
  end

  describe "load/1" do
    test "returns [] when there is no .nest", %{dir: dir} do
      assert {:ok, %{"mounts" => []}} = ProjectConfig.load(dir)
    end

    test "returns [] for a nil workspace" do
      assert {:ok, %{"mounts" => []}} = ProjectConfig.load(nil)
    end

    test "parses an rw mount and expands ~", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/data/x\"\nmode = \"rw\"\n")
      assert {:ok, %{"mounts" => [mount]}} = ProjectConfig.load(dir)
      assert mount["mode"] == "rw"
      assert mount["create"] == false
      assert mount["dest"] == Path.expand("~/data/x")
    end

    test "expands a relative path against the workspace", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"scratch\"\nmode = \"tmp\"\n")
      assert {:ok, %{"mounts" => [mount]}} = ProjectConfig.load(dir)
      assert mount["dest"] == Path.join(dir, "scratch")
    end

    test "parses create = true", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/data/y\"\nmode = \"rw\"\ncreate = true\n")
      assert {:ok, %{"mounts" => [mount]}} = ProjectConfig.load(dir)
      assert mount["create"] == true
    end

    test "parses [shell] background with a default of 1", %{dir: dir} do
      write_nest(dir, "[shell]\n")
      assert {:ok, config} = ProjectConfig.load(dir)
      assert config["shell"] == %{"background" => 1}

      # The rewrite is picked up with nothing cleared first: the bytes changed,
      # so the cache key changed.
      write_nest(dir, "[shell]\nbackground = 4\n")
      assert {:ok, %{"shell" => %{"background" => 4}}} = ProjectConfig.load(dir)
    end

    test "re-reads a rewritten .nest at an unchanged mtime and length", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/aaa\"\nmode = \"rw\"\n")
      assert {:ok, %{"mounts" => [first]}} = ProjectConfig.load(dir)
      assert first["dest"] == Path.expand("~/aaa")

      identity = identity_of(dir)

      # `~/bbb` is exactly as long as `~/aaa`, and the touch puts the file back
      # on the mtime the first parse was cached under, so nothing the filesystem
      # reports has changed. The premise is asserted below: without it the test
      # could pass because the identity moved, which would test nothing.
      write_nest(dir, "[[mount]]\npath = \"~/bbb\"\nmode = \"rw\"\n")
      File.touch!(nest_path(dir), identity.mtime)
      assert identity_of(dir) == identity

      assert {:ok, %{"mounts" => [second]}} = ProjectConfig.load(dir)
      assert second["dest"] == Path.expand("~/bbb")
    end
  end

  describe "load/1 validation" do
    test "rejects malformed and invalid .nest files", %{dir: dir} do
      cases = [
        {"not [valid", "invalid TOML"},
        {"[[mount]]\npath = \"~/x\"\nmode = \"bogus\"\n", "mode"},
        {"[[mount]]\nmode = \"rw\"\n", "path"},
        {"[[mount]]\npath = \"/\"\nmode = \"rw\"\n", "must not be /"},
        {"mount = 3\n", "array of tables"},
        {"[shell]\nbackground = -1\n", "non-negative integer"},
        {"[shell]\nbackground = \"x\"\n", "non-negative integer"},
        {"shell = 3\n", "shell must be a table"}
      ]

      Enum.each(cases, fn {body, needle} -> expect_error(dir, body, needle) end)
    end

    test "rejects duplicate dests", %{dir: dir} do
      body =
        "[[mount]]\npath = \"~/x\"\nmode = \"rw\"\n[[mount]]\npath = \"~/x\"\nmode = \"tmp\"\n"

      expect_error(dir, body, "duplicate")
    end

    test "reports a .nest it cannot read", %{dir: dir} do
      # A directory where the file should be is the cheapest way to make the
      # read fail, and unlike a permission bit it behaves the same for any user.
      File.mkdir_p!(nest_path(dir))

      log =
        capture_log(fn ->
          assert ProjectConfig.load(dir) == {:error, "could not read .nest: :eisdir"}
        end)

      # Asserted for inclusion only: `capture_log` collects every process's
      # lines, concurrent tests' included, so a count here would be fiction. An
      # unreadable `.nest` has no bytes and therefore no cache key, which is why
      # this failure is reported on *every* load rather than once. That is
      # deliberate — a `.nest` we cannot read must not degrade silently — and it
      # is not assertable from here.
      assert log =~ "could not read .nest"
    end
  end

  describe "effective_caps/2" do
    test "leaves a non-project mode unchanged", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/x\"\nmode = \"rw\"\n")
      caps = caps([])
      assert {:ok, ^caps} = ProjectConfig.effective_caps(caps, Mounts.new(dir, "/tmp/agent"))
    end

    test "adds project mounts and protected .nest", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/x\"\nmode = \"rw\"\n")
      assert {:ok, merged} = ProjectConfig.effective_caps(caps(), Mounts.new(dir, "/tmp/agent"))
      assert [%{"dest" => dest, "source" => source}] = merged["fs"]["project"]
      assert dest == Path.expand("~/x")
      assert source == dest
      assert [%{"path" => nest, "source" => nest_src}] = merged["fs"]["protected"]
      assert nest == Path.join(dir, ".nest")
      assert nest_src == nest
    end

    test "merges the shell background cap in a writable mode", %{dir: dir} do
      write_nest(dir, "[shell]\nbackground = 3\n")
      assert {:ok, merged} = ProjectConfig.effective_caps(caps(), Mounts.new(dir, "/tmp/agent"))
      assert merged["shell"] == %{"background" => 3}
    end

    test "also merges the shell cap in a read-only mode", %{dir: dir} do
      write_nest(dir, "[shell]\nbackground = 3\n")
      caps = caps([])
      assert {:ok, merged} = ProjectConfig.effective_caps(caps, Mounts.new(dir, "/tmp/agent"))
      assert merged["shell"] == %{"background" => 3}
      # Mounts remain gated: no project/protected keys in a read-only mode.
      assert merged["fs"] == caps["fs"]
    end

    test "a tmp mount sources from the agent tmp", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/scratch\"\nmode = \"tmp\"\n")
      assert {:ok, merged} = ProjectConfig.effective_caps(caps(), Mounts.new(dir, "/tmp/agent"))
      assert [%{"source" => source}] = merged["fs"]["project"]
      assert String.starts_with?(source, "/tmp/agent/project/")
    end

    test "masks /dev/null over a missing .nest", %{dir: dir} do
      assert {:ok, merged} = ProjectConfig.effective_caps(caps(), Mounts.new(dir, "/tmp/agent"))
      assert [%{"source" => "/dev/null"}] = merged["fs"]["protected"]
    end

    test "apply_or_default leaves caps unchanged when malformed", %{dir: dir} do
      write_nest(dir, "not [valid")

      log =
        capture_log(fn ->
          assert ProjectConfig.apply_or_default(caps(), Mounts.new(dir, "/tmp/agent")) == caps()
        end)

      assert log =~ "ignoring"
    end
  end

  describe "section/1" do
    test "is empty when there is no .nest", %{dir: dir} do
      assert ProjectConfig.section(dir) == ""
    end

    test "describes the configured mounts", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/x\"\nmode = \"rw\"\n")
      assert ProjectConfig.section(dir) =~ "Project sandbox config"
      assert ProjectConfig.section(dir) =~ Path.expand("~/x")
    end

    test "describes the shell background cap", %{dir: dir} do
      write_nest(dir, "[shell]\nbackground = 3\n")
      assert ProjectConfig.section(dir) =~ "at most 3 background shell job(s)"
    end

    test "renders a visible error for a malformed file", %{dir: dir} do
      write_nest(dir, "not [valid")

      log =
        capture_log(fn ->
          assert ProjectConfig.section(dir) =~ "Project sandbox config error"
        end)

      assert log =~ "ignoring"
    end
  end
end
