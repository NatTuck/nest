defmodule Nest.FileModesTest do
  @moduledoc """
  `Nest.FileModes` sets the mode on what it creates, because the BEAM cannot set
  a umask: without it the mode is whatever the launcher's umask leaves (this host's
  is `002`, so a plain `mkdir_p` is `0775`).
  """
  use ExUnit.Case, async: true

  import Nest.Test.FileMode

  alias Nest.FileModes

  setup do
    root =
      Path.join([
        File.cwd!(),
        "_build",
        "tmp",
        "nest_file_modes_#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(root)

    # The level that already exists: a caller's own 0700 must survive, which is
    # also what makes the "leaves an existing directory alone" claim assertable.
    File.chmod!(root, 0o700)

    on_exit(fn ->
      if String.contains?(root, "nest_file_modes"), do: File.rm_rf(root)
    end)

    %{root: root}
  end

  test "mkdir_p!/1 sets 0755 on the levels it created and leaves an existing one alone", %{
    root: root
  } do
    nested = Path.join([root, "space-1", "agent"])

    assert :ok = FileModes.mkdir_p!(nested)

    # Both levels are new, so both are the helper's to set; the root predates the
    # call, so its 0700 is not widened to 0755. The positive half is
    # host-dependent — on a launcher with umask 022 a plain `mkdir_p` also reads
    # 0755 — and no host-independent form exists, because the BEAM cannot set a
    # umask. The negative half below is the host-independent one.
    assert mode(nested) == 0o755
    assert mode(Path.dirname(nested)) == 0o755
    assert mode(root) == 0o700
  end

  test "write!/2 sets 0644 on a file that was already there with another mode", %{root: root} do
    path = Path.join(root, "job.log")
    File.write!(path, "")
    File.chmod!(path, 0o600)

    assert :ok = FileModes.write!(path, "out\n")

    # Host-independent, unlike a fresh file: a 0600 file only reads 0644 here if
    # the chmod ran, whatever the umask was.
    assert mode(path) == 0o644
    assert File.read!(path) == "out\n"
  end

  test "the tuple forms return :ok, or the error instead of raising", %{root: root} do
    dir = Path.join(root, "a")
    assert :ok = FileModes.mkdir_p(dir)
    assert mode(dir) == 0o755

    file = Path.join(dir, "f")
    assert :ok = FileModes.write(file, "x")
    assert mode(file) == 0o644

    # An unwritable parent: the tuple forms report it, the bang forms raise the
    # same `File.Error` the stdlib would, so a caller that matches on it (the
    # agent's init path does) keeps working.
    locked = Path.join(root, "locked")
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o700) end)

    assert {:error, reason} = FileModes.mkdir_p(Path.join(locked, "nope"))
    assert {:error, ^reason} = FileModes.write(Path.join(locked, "f"), "x")

    # The action strings are the stdlib's own, which is the whole reason the bang
    # forms build the error rather than raising `MatchError`.
    assert_raise File.Error, ~r/make directory \(with -p\)/, fn ->
      FileModes.mkdir_p!(Path.join(locked, "nope"))
    end

    assert_raise File.Error, ~r/write to file/, fn ->
      FileModes.write!(Path.join(locked, "f"), "x")
    end
  end
end
