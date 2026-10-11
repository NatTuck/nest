defmodule Nest.Tools.ShellPipesTest do
  @moduledoc """
  Tests for `Nest.Tools.ShellPipes`, the filter that rejects `shell-cmd`
  commands piping output into `head`, `tail`, or `grep`.

  `check/1` is pure — no bwrap, no I/O — so these run fast. The positive cases
  pin the pipeline detection (including by path, after redirections, and on a
  continuation line); the negative cases pin the false positives the tokenizer
  must avoid: quotes, comments, heredoc bodies, `||`/`&&`, and head/tail/grep
  used directly or as a filename.
  """

  use ExUnit.Case, async: true

  alias Nest.Tools.ShellPipes

  describe "check/1 rejects a pipe into head, tail, or grep" do
    test "rejects a pager at any pipeline stage, by bare name or by path" do
      for command <- [
            "ls | head",
            "ls | head -n 5",
            "cat big.log | tail -f",
            "ps aux | grep beam",
            "dmesg | grep -i error",
            "ls|head",
            "ls |& grep err",
            "a | b | head",
            "sort | uniq -c | sort -rn | head",
            "ls | /usr/bin/head",
            "ls | headless | grep x",
            "ls | grep"
          ] do
        assert {:error, message} = ShellPipes.check(command),
               "expected #{inspect(command)} to be rejected"

        assert message =~ "will not pipe command output into"
      end
    end

    test "names the offending command in the message" do
      assert {:error, head} = ShellPipes.check("ls | head")
      assert head =~ "into `head`"

      assert {:error, tail} = ShellPipes.check("ls | tail -f")
      assert tail =~ "into `tail`"

      assert {:error, grep} = ShellPipes.check("ls | grep x")
      assert grep =~ "into `grep`"
    end

    test "sees the command word after redirections and assignments" do
      # A redirection target or an assignment between the pipe and the command
      # must not hide the pager.
      for command <- ["cmd | > out head", "cmd | VAR=x head", "cmd | 2>/dev/null head"] do
        assert {:error, _message} = ShellPipes.check(command),
               "expected #{inspect(command)} to be rejected"
      end
    end

    test "treats |&, a subshell, a continuation line, and a following && as pipes" do
      for command <- [
            "ls |& tail",
            "ls\n| head",
            "ls \\\n| head",
            "ls |\nhead",
            "ps aux |\ngrep beam",
            "(ls | head)",
            "ls | (head)",
            "ls | head && echo done"
          ] do
        assert {:error, _message} = ShellPipes.check(command),
               "expected #{inspect(command)} to be rejected"
      end
    end

    test "rejects a pipe inside backticks or an unquoted command substitution" do
      # A backtick or unquoted `$(...)` runs real shell code, so a pipe inside
      # it is a real pipe into a pager.
      for command <- ["`ls | head`", "`ls | head -n 5`", "$(ls | head)"] do
        assert {:error, _message} = ShellPipes.check(command),
               "expected #{inspect(command)} to be rejected"
      end
    end
  end

  describe "check/1 allows commands that do not pipe into a pager" do
    test "allows head/tail/grep used directly or as an argument or filename" do
      for command <- [
            "head -1 file",
            "tail -f log",
            "grep foo file",
            "cat head.txt",
            "ls | headless",
            "echo hi > head"
          ] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "allows pipes into commands other than head, tail, or grep" do
      for command <- ["ls | sort", "ls | wc -l", "echo hi | tr a-z A-Z", "cat f | tee g"] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "does not treat ||, &&, or ; as a pipe" do
      for command <- ["make || head", "ls && head -1 f", "false; head -1 f"] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "ignores pipes inside quotes, comments, and heredoc bodies" do
      # The heredoc case is the issue's own "write a script and run it"
      # workaround: the body may legitimately contain a pipe into a pager.
      for command <- [
            ~s{echo "| head"},
            "echo 'a | grep b'",
            "echo # | head",
            "cat <<EOF\nls | head\nEOF",
            "cat <<'EOF'\nls | head\nEOF",
            "cat <<-EOF\n\tls | head\n\tEOF"
          ] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "handles degenerate shell syntax without a false positive" do
      # A comment with no newline, trailing backslashes (in and out of double
      # quotes), an arithmetic `<<` that is not a heredoc, and `<<` with a
      # missing or unclosed delimiter all stay `:ok`.
      for command <- [
            "ls # comment",
            "ls \\",
            ~s{echo "a\\},
            "echo $((1 << 2))",
            "cat << $file",
            "cat <<'EOF"
          ] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "allows command substitution that is double-quoted or has no pager pipe" do
      # A substitution inside double quotes is not inspected (a documented
      # limitation), and a substitution whose contents contain no pager pipe is
      # fine even when unquoted.
      for command <- [~s{echo "$(ls | head)"}, "echo `ls`", "head `ls`"] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end
  end

  describe "check/1 edge cases" do
    test "accepts a non-binary command, which the tool schema rejects elsewhere" do
      assert :ok = ShellPipes.check(nil)
      assert :ok = ShellPipes.check(123)
    end

    test "returns :ok for an empty command" do
      assert :ok = ShellPipes.check("")
    end
  end
end
