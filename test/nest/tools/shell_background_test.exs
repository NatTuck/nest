defmodule Nest.Tools.ShellBackgroundTest do
  @moduledoc """
  Tests for `Nest.Tools.ShellBackground`, the filter that rejects `shell-cmd`
  commands asking for a *detached* background job (`setsid`, `nohup`, or an
  unquoted `&`).

  `check/1` is pure — no bwrap, no I/O — so these run fast. The rejection cases
  pin the marker that names the reason; the allowance cases pin the false
  positives the tokenizer must avoid: `&&`, `&>`/`&>>`, `2>&1`, `&` inside
  quotes, comments, and heredoc bodies, and `setsid`/`nohup` as an argument or
  filename rather than a command word.
  """

  use ExUnit.Case, async: true

  alias Nest.Tools.ShellBackground

  describe "check/1 rejects a detached-background marker" do
    test "rejects setsid and nohup as a stage's command word, by bare name or by path" do
      for {command, marker} <- [
            {"setsid sleep 1", "setsid"},
            {"nohup sleep 1", "nohup"},
            {"sleep 1 && setsid sleep 2", "setsid"},
            {"ls | nohup sleep 2", "nohup"},
            {"(setsid sleep 1)", "setsid"},
            {"/usr/bin/setsid sleep 1", "setsid"},
            {"/usr/bin/nohup sleep 1", "nohup"}
          ] do
        assert {:error, message} = ShellBackground.check(command),
               "expected #{inspect(command)} to be rejected"

        assert message =~ "`#{marker}`"
        assert message =~ "background: true"
      end
    end

    test "rejects an unquoted & wherever it backgrounds a stage" do
      for command <- [
            "sleep 1 &",
            "sleep 1 & wait",
            "ls | sleep 1 &",
            "(sleep 1 &)",
            "sleep 1 &\nsleep 2",
            "a&b"
          ] do
        assert {:error, message} = ShellBackground.check(command),
               "expected #{inspect(command)} to be rejected"

        assert message =~ "`&`"
      end
    end
  end

  describe "check/1 allows commands that do not detach" do
    test "allows &&, &>, &>>, and the >& and <& redirections" do
      for command <- [
            "cmd1 && cmd2",
            "cmd &> out.log",
            "cmd &>> out.log",
            "cmd 2>&1",
            "cmd >&2",
            "cmd <&0"
          ] do
        assert :ok = ShellBackground.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "ignores & inside quotes, comments, and heredoc bodies" do
      for command <- [
            ~s{echo "a & b"},
            "echo 'a & b'",
            "echo a\\&b",
            "echo # a & b",
            "cat <<EOF\na & b\nEOF",
            "cat <<'EOF'\nsleep 1 &\nEOF"
          ] do
        assert :ok = ShellBackground.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "allows setsid and nohup that are not a stage's command word" do
      for command <- [
            "echo nohup",
            "grep -e setsid file",
            "cat nohup.txt",
            "command nohup sleep 1",
            "setsid=1 echo hi"
          ] do
        assert :ok = ShellBackground.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "documents the known misses so the moduledoc cannot drift" do
      # The marker must be the stage's own command word and must not be quoted:
      # a wrapper, a shell-keyword or brace-group stage, and a marker nested
      # inside another shell are not caught — the same wrapper/quoting gap
      # `ShellPipes` documents.
      for command <- [
            ~s{sh -c 'sleep 1 &'},
            ~s{echo "$(sleep 1 &)"},
            "xargs setsid sleep 1",
            "if true; then nohup sleep 1; fi",
            "{ setsid sleep 1; }"
          ] do
        assert :ok = ShellBackground.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "defers a non-string command to ShellPipes, which owns the type check" do
      # `nil` is the boundary; the clause is one catch-all, so every non-string
      # takes the same path.
      assert :ok = ShellBackground.check(nil)
    end
  end
end
