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
    assert {:error, message} = ShellCmd.execute("true", "/tmp", nil, nil, [])

    assert message =~ "Exit code 130"
    assert message =~ "[Command cancelled]"
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
end
