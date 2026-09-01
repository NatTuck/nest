defmodule Nest.Tools.ShellCmdTest do
  @moduledoc """
  Tests for `Nest.Tools.ShellCmd`. Focus: the `{:stop_chat, _}`
  clause in `collect_output/3` that kills the bwrap OS process
  when the user clicks Stop mid-execution.

  Uses real bwrap + `:exec.run/2` (no mocks) — the tool is
  exercised end-to-end. The test pre-seeds the calling
  process's mailbox with `{:stop_chat, self()}` so that
  `collect_output/3`'s `receive` matches it on the first
  iteration instead of waiting for the command to complete
  naturally. This keeps the test fast (sub-second) without
  requiring mocks or a long-running command.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Nest.Tools.ShellCmd

  @tag :bwrap
  test "collect_output/3's {:stop_chat, _} clause calls :exec.stop and returns exit 130" do
    # Pre-seed the mailbox so the receive clause matches on
    # the first iteration. Without this, `collect_output/3`
    # would block on `:stdout` / `:stderr` / `:DOWN` until
    # the command's natural exit (or the 60s default timeout).
    send(self(), {:stop_chat, self()})

    # Use `true` (a no-op builtin) so we don't depend on a
    # specific toolchain being installed. bwrap still spawns
    # the process and `:exec.run/2` returns the os_pid —
    # that's what `collect_output/3` needs to forward to
    # `:exec.stop/1`.
    log =
      capture_log(fn ->
        assert {:error, message} = ShellCmd.execute("true", "/tmp", nil, nil, [])

        assert message =~ "Exit code 130"
        assert message =~ "[Command cancelled]"
      end)

    # The bwrap non-zero exit on cancel is a deliberate
    # diagnostic — assert on it so the test's intent is
    # self-documenting and the log doesn't escape.
    assert log =~ "ShellCmd.execute: bwrap exited non-zero"
    assert log =~ "exit_code=130"
  end

  test "execute/5 returns the natural output for a successful command" do
    # Sanity check that the receive doesn't match the
    # pre-seeded stop when none is in the mailbox. A trivial
    # `true` command exits 0 immediately and bwrap reports
    # the success path.
    assert {:ok, output} = ShellCmd.execute("true", "/tmp", nil, nil, [])

    # The output is the "no output" placeholder because
    # `true` produces no stdout/stderr.
    assert output == "[Command executed successfully with no output]"
  end

  @tag :bwrap
  test "a symlinked workspace is bound at its canonical path; read and write work through the symlink" do
    uniq = System.unique_integer([:positive])
    base = System.tmp_dir!()
    real = Path.join(base, "nest_bwrap_#{uniq}_real")
    link = Path.join(base, "nest_bwrap_#{uniq}_link")

    File.mkdir_p!(real)
    File.ln_s!(real, link)
    on_exit(fn -> File.rm_rf([real, link]) end)

    File.write!(Path.join(real, "hello.txt"), "symlink-ok\n")

    # Default caps bind the canonical workspace read-write; --chdir
    # targets the user's symlinked path. Reading and writing through
    # the symlink must resolve to the canonical writable mount.
    assert {:ok, output} = ShellCmd.execute("cat hello.txt", link, nil, nil, [])
    assert output =~ "symlink-ok"

    assert {:ok, _} = ShellCmd.execute("echo written > out.txt", link, nil, nil, [])
    assert File.read!(Path.join(real, "out.txt")) =~ "written"
  end

  test "a missing workspace fails without bwrap creating it" do
    missing = Path.join(System.tmp_dir!(), "nest_missing_#{System.unique_integer([:positive])}")

    # The workspace is validated before bwrap runs, so a missing
    # directory surfaces as a failure and is never auto-created.
    assert_raise RuntimeError, ~r/does not exist/, fn ->
      ShellCmd.execute("true", missing, nil, nil, [])
    end

    refute File.exists?(missing)
  end
end
