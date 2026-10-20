defmodule Nest.Tools.ShellPipesTest do
  @moduledoc """
  Tests for `Nest.Tools.ShellPipes`, the filter that rejects `shell-cmd`
  commands piping output into `head` or `tail`.

  `check/1` is pure — no bwrap, no I/O — so these run fast. The positive cases
  pin the pipeline detection (including by path, after redirections, and on a
  continuation line); the negative cases pin the false positives the tokenizer
  must avoid: quotes, comments, heredoc bodies, `||`/`&&`, `head` used directly
  or as a filename, and a pipe into `grep`, which is allowed (issue #106).
  """

  use ExUnit.Case, async: true

  alias Nest.Tools.ShellPipes

  describe "check/1 rejects a pipe into head or tail" do
    test "rejects a pager at any pipeline stage, by bare name or by path, and names it" do
      for {command, pager} <- [
            {"ls | head", "head"},
            {"cat big.log | tail -f", "tail"},
            {"ls|head", "head"},
            {"a | b | head", "head"},
            {"ls | /usr/bin/head", "head"},
            {"(( x << 1 ))\nls | head", "head"}
          ] do
        assert {:error, message} = ShellPipes.check(command),
               "expected #{inspect(command)} to be rejected"

        assert message =~ "will not pipe command output into `#{pager}`"
      end
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
      for command <- ["`ls | head`", "$(ls | head)"] do
        assert {:error, _message} = ShellPipes.check(command),
               "expected #{inspect(command)} to be rejected"
      end
    end

    test "rejects a pipe on the heredoc line, and code after the body" do
      # Only the heredoc *body* is skipped: a pipe on the `<<` line is a real
      # pipeline, and so is code after the closing delimiter. An undecidable
      # delimiter (`<<E'OF'`, whose text is `EOF` to bash) still scans the rest
      # of the line, so the pipe there is caught.
      for command <- [
            "cat <<EOF | head",
            "cat <<E'OF' | head",
            "cat <<EOF\nls | head\nEOF\nls | head"
          ] do
        assert {:error, _message} = ShellPipes.check(command),
               "expected #{inspect(command)} to be rejected"
      end
    end

    test "rejects an unquoted | in a case pattern list and in an awk regex" do
      # A `case` pattern list uses `|` to separate alternatives, not to pipe, so
      # refusing `case $x in head|tail)` is the one documented false positive
      # (the walk does not track command-word position). `awk /head|tail/ file`
      # is refused for the same reason but there it is *correct*: bash tokenizes
      # that `|` as a pipe and tries to run `tail/`, so the regex must be quoted.
      for command <- ["case $x in head|tail) echo ok;; esac", "awk /head|tail/ file"] do
        assert {:error, _message} = ShellPipes.check(command),
               "expected #{inspect(command)} to be rejected"
      end
    end
  end

  describe "check/1 allows commands that do not pipe into a pager" do
    test "allows head used directly or as a filename, and a quoted |" do
      # A pager only counts when it is a pipeline stage's command word, and the
      # match is the exact basename: `head.txt` and `headless` are not pagers,
      # and a `|` inside quotes is not a pipe.
      for command <- ["head -1 file", "cat head.txt", "ls | headless", "awk '/head|tail/' file"] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "allows a pipe into a command that is not a pager, including grep (issue #106)" do
      # `grep` selects rather than truncates, so it is a legitimate filter and
      # piping into it is allowed — the filter refuses only `head` and `tail`.
      for command <- ["ls | sort", "ls | grep x"] do
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
            "cat <<-EOF\n\tls | head\n\tEOF",
            "cat <<\\EOF\nls | head\nEOF",
            "cat <<'E OF'\nls | head\nE OF",
            "cat <<$F\nls | head\n$F",
            "cat <<E'OF'\nls | head\nEOF",
            "cat <<\\-EOF\nls | head\nEOF"
          ] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "handles degenerate shell syntax without a false positive" do
      # An empty command, trailing backslashes (in and out of double quotes), an
      # arithmetic `<<` that is not a heredoc, and `<<` with no body or an
      # unclosed quoted delimiter all stay `:ok`.
      for command <- [
            "",
            "ls \\",
            ~s{echo "a\\},
            "echo $((1 << 2))",
            "cat << $file",
            "cat <<'EOF"
          ] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "a newline ends the stage once content was consumed after the pipe" do
      # A bare `|` + newline is a continuation, but once the stage has an
      # assignment or a redirection the newline ends it — bash runs `head` as a
      # separate command.
      for command <- ["ls | 2>/dev/null\nhead -1 g", "ls |\nVAR=x\nhead -1 f"] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "documents the known misses so the moduledoc cannot drift" do
      # These are the limitations named in the moduledoc: the pager is not the
      # stage's own command word (a wrapper, a brace group, or an argument), so
      # the filter does not catch it.
      for command <- ["ls | xargs head", "ls | { head; }", "ls | env head"] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end

    test "allows command substitution that is double-quoted or has no pager pipe" do
      # A substitution inside double quotes is not inspected (a documented
      # limitation), and a substitution whose contents contain no pager pipe is
      # fine even when unquoted.
      for command <- [~s{echo "$(ls | head)"}, "echo `ls`"] do
        assert :ok = ShellPipes.check(command), "expected #{inspect(command)} to be allowed"
      end
    end
  end

  describe "check/1 edge cases" do
    test "rejects a non-binary command with the same shape as the timeout error" do
      # `Nest.LLM.Tools` only checks that the `command` key is present, so a
      # non-string value reaches here; it must not crash `ShellCmd`.
      for bad <- [nil, ["echo X | head"]] do
        assert {:error, message} = ShellPipes.check(bad)

        assert message ==
                 "Invalid `command` argument: expected a string, got: #{inspect(bad)}."
      end
    end
  end
end
