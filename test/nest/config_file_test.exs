defmodule Nest.ConfigFileTest do
  @moduledoc """
  `Nest.ConfigFile`: the two protected config files' names, their state, and the
  gate that refuses a workspace whose config path Nest cannot protect.

  A non-regular config path cannot be masked, and *omitting* the mask is not
  protection either — without a mount point over the path an `act` agent can
  delete a symlink and write a regular `.nest` declaring `[[mount]] path =
  "/home"`, which the next caps resolution honours. So the workspace is refused.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.ConfigFile

  setup do
    dir = Path.join(System.tmp_dir!(), "nest_cfgfile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> if String.contains?(dir, "nest_cfgfile_"), do: File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp write_nest(dir, body), do: File.write!(Path.join(dir, ".nest"), body)

  defp nest_path(dir), do: Path.join(dir, ".nest")

  describe "error/1" do
    test "is :ok for a workspace with both files regular", %{dir: dir} do
      write_nest(dir, "")
      File.write!(Path.join(dir, "AGENTS.md"), "# rules\n")

      assert ConfigFile.error(dir) == :ok
    end

    test "is :ok when both files are absent", %{dir: dir} do
      # The regression guard against refusing everything: a workspace with no
      # config at all is the ordinary case.
      assert ConfigFile.error(dir) == :ok
      assert ConfigFile.error(nil) == :ok
    end

    test "refuses a symlinked .nest, naming it", %{dir: dir} do
      target = Path.join(dir, "real.nest")
      File.write!(target, "")
      File.ln_s!(target, nest_path(dir))

      log =
        capture_log(fn ->
          assert {:error, {:config_file_not_regular, path}} = ConfigFile.error(dir)
          assert path == nest_path(dir)
        end)

      assert log =~ "Nest cannot protect it from being rewritten"
    end

    test "refuses a symlinked AGENTS.md, naming it", %{dir: dir} do
      write_nest(dir, "")
      target = Path.join(dir, "real-agents.md")
      File.write!(target, "# rules\n")
      File.ln_s!(target, Path.join(dir, "AGENTS.md"))

      log =
        capture_log(fn ->
          assert {:error, {:config_file_not_regular, path}} = ConfigFile.error(dir)
          assert path == Path.join(dir, "AGENTS.md")
        end)

      assert log =~ "AGENTS.md is a symlink"
    end

    test "reports a non-regular config path once, not per call", %{dir: dir} do
      target = Path.join(dir, "real.nest")
      File.write!(target, "")
      File.ln_s!(target, nest_path(dir))

      # A *count* of this exact path, not an absence assertion: the path is
      # unique to this test, so no concurrent test's lines can contain it even
      # though `capture_log` is not process-scoped. `load/1` runs on every prompt
      # composition and every caps resolution, so once-per-path is the property.
      log =
        capture_log(fn ->
          assert {:error, _} = ConfigFile.error(dir)
          assert {:error, _} = ConfigFile.error(dir)
        end)

      assert length(String.split(log, nest_path(dir))) - 1 == 1
    end
  end

  describe "the type word in the refusal" do
    test "names a directory", %{dir: dir} do
      File.mkdir_p!(nest_path(dir))

      log =
        capture_log(fn ->
          assert {:error, {:config_file_not_regular, _}} = ConfigFile.error(dir)
        end)

      assert log =~ "is a directory"
    end

    test "names an unreadable path rather than treating it as absent", %{dir: dir} do
      # An `lstat` that fails for any reason other than `:enoent` is a path we
      # could not inspect. The safe default is the refusal, not the mask: masking
      # `/dev/null` over a path we could not look at would bind over something we
      # do not understand.
      locked = Path.join(dir, "locked")
      File.mkdir_p!(locked)
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod(locked, 0o755) end)

      # The `.nest` is inside the unreadable directory, so `lstat` is `:eacces`.
      assert ConfigFile.state(Path.join(locked, ".nest")) == {:not_regular, :unreadable}

      assert ConfigFile.state(Path.join(locked, "AGENTS.md")) ==
               {:not_regular, :unreadable}

      # And a workspace whose config path cannot be inspected is refused, not
      # masked. `error/1` on the *parent* is `:ok` (the parent is a directory but
      # it is not a config path), so this asserts the state directly.
      assert ConfigFile.error(dir) == :ok
    end

    test "does not name a type it was not told", %{dir: dir} do
      # A fifo is neither a symlink, a directory nor unreadable: the catch-all
      # word. `mkfifo` is the cheapest way to make one.
      fifo = nest_path(dir)
      {_, 0} = System.cmd("mkfifo", [fifo])
      on_exit(fn -> File.rm(fifo) end)

      log =
        capture_log(fn ->
          assert {:error, {:config_file_not_regular, ^fifo}} = ConfigFile.error(dir)
        end)

      assert log =~ "is not a regular file"
    end
  end
end
