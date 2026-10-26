defmodule Nest.ProjectConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Nest.Test.FileMode

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
        {"shell = 3\n", "shell must be a table"},
        {"[sandbox]\npackages = \"nodejs\"\n", "packages must be a list"},
        {"[sandbox]\npackages = [3]\n", "Debian package names"},
        {"[sandbox]\npackages = [\"-bad\"]\n", "Debian package names"},
        {"sandbox = 3\n", "sandbox must be a table"}
      ]

      Enum.each(cases, fn {body, needle} -> expect_error(dir, body, needle) end)
    end

    test "rejects duplicate dests", %{dir: dir} do
      body =
        "[[mount]]\npath = \"~/x\"\nmode = \"rw\"\n[[mount]]\npath = \"~/x\"\nmode = \"tmp\"\n"

      expect_error(dir, body, "duplicate")
    end

    test "reports a regular .nest it cannot read", %{dir: dir} do
      # A *regular* file with no read bit: the one state that still reaches the
      # error branch. A directory (or a symlink) is a non-regular path, and that
      # is a different answer — it grants nothing, and the *workspace* is refused
      # (see the describe below).
      write_nest(dir, "")
      File.chmod!(nest_path(dir), 0o000)

      on_exit(fn -> File.chmod(nest_path(dir), 0o644) end)

      # This needs a **non-root** user: root can read a mode-`000` file, so
      # `load/1` would succeed and the assertion below would fail. The suite runs
      # as the developer's own user, never as root.
      log =
        capture_log(fn ->
          assert ProjectConfig.load(dir) == {:error, "could not read .nest: :eacces"},
                 "as root a mode-000 file is still readable — this test needs a non-root user"
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

  describe "a config path that is not a regular file" do
    test "load/1 refuses a symlinked .nest and never follows the link", %{dir: dir} do
      # The *gate* owns the warning (`Nest.ConfigFile.error/1`); `load/1` only has
      # to not follow the link, and to say so where a reader sees it. This is the
      # re-render path — a running agent whose file was replaced — so it is not
      # the gate's business.
      target = Path.join(dir, "real.nest")
      File.write!(target, "[[mount]]\npath = \"~/x\"\nmode = \"rw\"\n")
      File.ln_s!(target, nest_path(dir))

      # No capture: `load/1` logs nothing (the gate does), so this also proves it
      # prints nothing. "The path is not in the log" is not assertable through
      # `capture_log` at all, since it collects every process's lines.
      assert {:error, reason} = ProjectConfig.load(dir)
      assert reason =~ "not a regular file"

      # And it grants nothing, visibly: the reason reaches the prompt and the
      # target's `[[mount]]` never applies.
      section = ProjectConfig.section(dir)
      assert section =~ "[Project sandbox config error]"
      assert section =~ "not a regular file"
      refute section =~ "~/x"
    end

    test "a symlinked config file contributes no protected entry", %{dir: dir} do
      # `.nest` is a regular file, `AGENTS.md` is a symlink: the first is masked
      # over itself, the second gets no entry. That omission is **defensive
      # only** — it is not protection, because with no mount point over the path
      # an `act` agent could delete the link and write a regular file. The
      # mechanism is `Nest.ConfigFile.error/1`, which refuses the workspace; this
      # pins what the bind list looks like if anything ever asks anyway.
      write_nest(dir, "")
      File.write!(Path.join(dir, "real-agents.md"), "# rules\n")
      File.ln_s!(Path.join(dir, "real-agents.md"), Path.join(dir, "AGENTS.md"))

      assert {:ok, merged} = ProjectConfig.effective_caps(caps(), Mounts.new(dir, "/tmp/agent"))

      assert [%{"path" => nest}] = merged["fs"]["protected"]
      assert nest == nest_path(dir)
    end
  end

  describe "effective_caps/2" do
    test "leaves a non-project mode unchanged", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/x\"\nmode = \"rw\"\n")
      caps = caps([])
      assert {:ok, ^caps} = ProjectConfig.effective_caps(caps, Mounts.new(dir, "/tmp/agent"))
    end

    test "adds project mounts and protects .nest and AGENTS.md", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/x\"\nmode = \"rw\"\n")
      File.write!(Path.join(dir, "AGENTS.md"), "# Project rules\n")

      assert {:ok, merged} = ProjectConfig.effective_caps(caps(), Mounts.new(dir, "/tmp/agent"))
      assert [%{"dest" => dest, "source" => source}] = merged["fs"]["project"]
      assert dest == Path.expand("~/x")
      assert source == dest

      # Both human-authored config files are masked read-only, each sourced from
      # the real file when it is there (issue #97).
      assert [
               %{"path" => nest, "source" => nest_src},
               %{"path" => agents_md, "source" => agents_md_src}
             ] = merged["fs"]["protected"]

      assert nest == Path.join(dir, ".nest")
      assert nest_src == nest
      assert agents_md == Path.join(dir, "AGENTS.md")
      assert agents_md_src == agents_md
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

    test "masks /dev/null over a missing .nest and a missing AGENTS.md", %{dir: dir} do
      # Neither file exists in this fixture. The mask is what stops an agent
      # *creating* one — which would be picked up on the next spawn, granting
      # extra host access (`.nest`) or quietly changing its own prompt
      # (`AGENTS.md`).
      assert {:ok, merged} = ProjectConfig.effective_caps(caps(), Mounts.new(dir, "/tmp/agent"))

      assert [
               %{"path" => nest, "source" => "/dev/null"},
               %{"path" => agents_md, "source" => "/dev/null"}
             ] = merged["fs"]["protected"]

      assert nest == Path.join(dir, ".nest")
      assert agents_md == Path.join(dir, "AGENTS.md")
    end

    test "resolve_caps leaves caps unchanged when malformed", %{dir: dir} do
      write_nest(dir, "not [valid")

      log =
        capture_log(fn ->
          assert ProjectConfig.resolve_caps(caps(), Mounts.new(dir, "/tmp/agent")) == caps()
        end)

      assert log =~ "ignoring"
    end
  end

  describe "the [sandbox] packages" do
    test "are carried in caps for every mode, like the shell cap", %{dir: dir} do
      write_nest(dir, "[sandbox]\npackages = [\"nodejs\", \"elixir\"]\n")

      # A read-only mode gets them too: tooling inside the container is not a
      # filesystem grant.
      assert {:ok, merged} = ProjectConfig.effective_caps(caps([]), Mounts.new(dir, "/tmp/agent"))
      assert ProjectConfig.sandbox_packages(merged) == ["nodejs", "elixir"]
    end

    test "are deduplicated and read back from caps alone", %{dir: dir} do
      write_nest(dir, "[sandbox]\npackages = [\"nodejs\", \"nodejs\"]\n")

      assert {:ok, merged} = ProjectConfig.effective_caps(caps(), Mounts.new(dir, "/tmp/agent"))
      assert ProjectConfig.sandbox_packages(merged) == ["nodejs"]
    end

    test "are empty when .nest declares none", %{dir: dir} do
      write_nest(dir, "[[mount]]\npath = \"~/x\"\nmode = \"rw\"\n")

      assert ProjectConfig.sandbox_packages(caps()) == []

      assert {:ok, merged} = ProjectConfig.effective_caps(caps(), Mounts.new(dir, "/tmp/agent"))
      assert ProjectConfig.sandbox_packages(merged) == []
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

    test "names the packages and where they are", %{dir: dir} do
      # The `empty_config?/1` guard has to count them, or a `.nest` that only
      # declares packages would render nothing at all — which is why the package
      # line's presence below is also the assertion that a package-only config
      # renders a section.
      write_nest(dir, "[sandbox]\npackages = [\"nodejs\"]\n")

      assert ProjectConfig.section(dir) =~
               "docker sandbox image with these packages: nodejs"
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

  test "the canonical-workspace memo's table outlives the process that first reads it", %{
    dir: dir
  } do
    # The table is created by `Nest.Application.start/2`, not lazily. Created
    # lazily it was owned by whichever process read a workspace first — usually an
    # agent composing a prompt — so stopping that agent deleted the table and the
    # next reader died with "the table identifier does not refer to an existing
    # ETS table". A `Task` is the cheapest stand-in for that short-lived reader:
    # if the table were created here it would die with the task.
    #
    # Caps resolution, not `load/1`: a workspace with no `.nest` answers `:absent`
    # before anything is canonicalised, so `load/1` never touches the memo. The
    # memo is reached from `protected_entries/1` via `effective_caps/2`, and that
    # is what has to happen in the short-lived process for this to mean anything.
    Task.async(fn -> ProjectConfig.effective_caps(caps(), Mounts.new(dir, nil)) end)
    |> Task.await()

    assert :ets.lookup(:nest_project_config_cache, {:workspace, dir}) != []
  end

  describe "ensure_dirs/1" do
    test "the tmp source is Nest's, so it is 0755; an rw destination is the user's", %{dir: dir} do
      # A `tmp` mount's source is `<scratch>/project/<slug>` — Nest's own
      # directory, bound *read-write* into the agent's sandbox — so it gets
      # `Nest.FileModes`. An `rw` destination is a path the user named in
      # `.nest`: it is created, and its mode is not ours to set.
      source = Path.join([dir, "scratch", "project", "0123456789abcdef"])
      dest = Path.join([dir, "user", "mount"])

      caps = %{
        "net" => false,
        "fs" => %{
          "read" => ["/"],
          "write" => [":workspace"],
          "project" => [
            %{"mode" => "tmp", "dest" => "~/scratch", "source" => source},
            %{"mode" => "rw", "dest" => dest, "create" => true}
          ]
        }
      }

      assert :ok = ProjectConfig.ensure_dirs(caps)

      # Both new levels are the helper's; a 022 launcher would give the same
      # answer, so the assertion earns its keep on this host's 002.
      assert mode(source) == 0o755
      assert mode(Path.dirname(source)) == 0o755

      # Only that it exists: the destination's mode is not Nest's to set, and
      # that is not pinnable host-independently — a `FileModes`-forced 0755 and a
      # umask-022 plain `mkdir_p` are the same observable.
      assert File.dir?(dest)
    end
  end
end
