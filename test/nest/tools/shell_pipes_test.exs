defmodule Nest.Tools.ShellPipesTest do
  @moduledoc """
  Tests for `Nest.Tools.ShellPipes`, which refuses a piped `shell-cmd` command
  that can run longer than 30 seconds and accepts everything else as written.
  """

  use ExUnit.Case, async: true

  alias Nest.Tools.ShellPipes

  @long 31_000
  @short 30_000

  # A top-level pipe, whatever it pipes into: the rule never looks at the stage,
  # because the tool no longer rewrites one.
  @piped [
    "ls | head",
    "ls | head -5",
    "ls | tail -n 20",
    "ls | grep x",
    "ls | cat",
    "ls | head | cat",
    "ls |& tail",
    "ls | head > out.txt",
    "ls | head; echo done",
    "ls | xargs head",
    "ls | (head)",
    "ls | { head; }",
    "cat <<EOF | head"
  ]

  # No top-level pipe: a quoted pipe, a substitution, a subshell, a heredoc body.
  @unpiped [
    "ls",
    "ls -la",
    ~s{echo "a | head"},
    "echo 'a | head'",
    "$(ls | head)",
    "`ls | head`",
    "(ls | head)",
    "cat <<'EOF'\nls | head\nEOF"
  ]

  test "a pipe is refused above the bound and accepted at or below it" do
    for command <- @piped do
      assert {:error, message} = ShellPipes.check(command, @long, false), command
      assert message == ShellPipes.refusal()

      assert :ok == ShellPipes.check(command, @short, false), command
      assert :ok == ShellPipes.check(command, 1_000, false), command
    end
  end

  test "a command with no top-level pipe is accepted at any bound" do
    for command <- @unpiped, timeout <- [@long, @short], background <- [false, true] do
      assert :ok == ShellPipes.check(command, timeout, background), command
    end
  end

  test "a background job is unbounded, so its pipes are refused" do
    for command <- @piped do
      assert {:error, _} = ShellPipes.check(command, @short, true), command
      assert {:error, _} = ShellPipes.check(command, @long, true), command
    end
  end

  test "the refusal names a script, a log under /tmp, and the way out" do
    message = ShellPipes.refusal()

    assert message =~ "more than 30 seconds"
    assert message =~ "file-write"
    assert message =~ "shell-cmd sh run.sh"
    assert message =~ "/tmp/<your-name>/build.log"
    assert message =~ "background: true"
    assert message =~ "timeout: 30"
  end

  test "rejects a non-binary command with the same shape as the timeout error" do
    # The tool's schema only checks that the `command` key is present, so a
    # non-string value reaches here; it must not crash `ShellCmd`.
    for bad <- [nil, ["echo X | head"]] do
      assert {:error, message} = ShellPipes.check(bad, @long, false)

      assert message ==
               "Invalid `command` argument: expected a string, got: #{inspect(bad)}."
    end
  end
end
