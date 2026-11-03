defmodule Nest.Tools.ShellTokensTest do
  @moduledoc """
  The tokenizer's own edges, and the one thing a caller cuts with:
  `split_last_stage/1`.

  `Nest.Tools.ShellPipes` classifies a stage, but it never sees the *split*: a
  byte offset that is off by one produces a plausible-but-different command, and
  the classifier cannot notice because it is only ever handed the stage the
  splitter chose. So every case here is asserted as either "no cut" (`:none`) or
  "the last top-level stage is exactly this" — both are correct answers; the
  point is that none of them is a wrong one.

  `tokenize/1` is pinned alongside, because two other callers depend on its
  output shape (`command_words/1` for `ShellBackground.check/1`, and
  `ShellPipes`'s own stage tokenizing): the offsets the splitter uses are
  internal, and must not leak into the token stream.
  """

  use ExUnit.Case, async: true

  alias Nest.Tools.ShellTokens

  describe "split_last_stage/1 finds the last top-level pipe" do
    test "the plain cases, so the pins below are anchored" do
      assert ShellTokens.split_last_stage("ls | head") == {"ls ", " head"}
      assert ShellTokens.split_last_stage("ls|head") == {"ls", "head"}
      assert ShellTokens.split_last_stage("ls | grep x | head") == {"ls | grep x ", " head"}
      assert ShellTokens.split_last_stage("ls | head | wc -l") == {"ls | head ", " wc -l"}
      assert ShellTokens.split_last_stage("head -1 file") == :none
      assert ShellTokens.split_last_stage("") == :none
    end

    test "an escaped pipe is a word, not an operator" do
      # `ls \| head` runs `ls` with two arguments; bash never pipes it.
      assert ShellTokens.split_last_stage("ls \\| head") == :none
      assert ShellTokens.tokenize("ls \\| head") == [word: "ls", word: "|", word: "head"]
    end

    test "`||` is not a pipe, and `|&` is" do
      assert ShellTokens.split_last_stage("ls || head") == :none
      assert ShellTokens.tokenize("ls || head") == [word: "ls", op: "||", word: "head"]

      assert ShellTokens.split_last_stage("ls |& head") == {"ls ", " head"}
      assert ShellTokens.tokenize("ls |& head") == [word: "ls", op: "|&", word: "head"]
    end

    test "a pipe inside quotes is not a pipe, including quotes inside quotes" do
      assert ShellTokens.split_last_stage(~s{echo "a | head"}) == :none
      assert ShellTokens.split_last_stage("echo 'a | b'") == :none
      # Single quotes inside a double-quoted string are literal characters, so
      # the pipe between them is still quoted.
      assert ShellTokens.split_last_stage(~s{echo "it's 'a | b'"}) == :none

      assert ShellTokens.tokenize("echo 'a | b'") == [word: "echo", word: "a | b"]
    end

    test "a pipe inside a substitution or a subshell belongs to the stage that holds it" do
      assert ShellTokens.split_last_stage("echo $(ls | head)") == :none
      assert ShellTokens.split_last_stage("`ls | head`") == :none
      assert ShellTokens.split_last_stage("(ls | head)") == :none

      # `ls | (head)` is the other way round: the pipe *is* top-level and the
      # stage after it is the subshell, so the split is here and the stage is
      # `(head)`. `ShellPipes` declines it (a stage whose first token is not a
      # word is not a truncator), which is the safe direction.
      assert ShellTokens.split_last_stage("ls | (head)") == {"ls ", " (head)"}

      # The token stream is unchanged by the offsets: the substitution's pipe is
      # an operator token exactly as it was before `split_last_stage/1` existed.
      assert ShellTokens.tokenize("`ls | head`") == [word: "ls", op: "|", word: "head"]

      assert ShellTokens.tokenize("echo $(ls | head)") == [
               word: "echo",
               word: "$",
               op: "(",
               word: "ls",
               op: "|",
               word: "head",
               op: ")"
             ]
    end

    test "a newline separates commands, with or without a pipe on the second line" do
      assert ShellTokens.split_last_stage("cd /x\nls") == :none
      assert ShellTokens.split_last_stage("cd /x\nls | head") == {"cd /x\nls ", " head"}
      # A pipe with nothing after it on its line is a continuation, not a cut
      # point of its own: the stage is the one on the next line.
      assert ShellTokens.split_last_stage("ls |\nhead") == {"ls ", "\nhead"}
    end
  end

  describe "split_last_stage/1 leaves heredocs, comments and arithmetic alone" do
    test "a heredoc's body is skipped, and its delimiter's quoting does not change that" do
      # Every shape here puts the pipe inside the body. The delimiter forms are
      # the tokenizer's: quoted, escaped, `<<-` (tabs), a variable-shaped word,
      # and the undecidable `<<E'OF'` sentinel.
      for command <- [
            "cat <<EOF\nls | head\nEOF",
            "cat <<'EOF'\nls | head\nEOF",
            "cat <<-EOF\n\tls | head\n\tEOF",
            "cat <<\\EOF\nls | head\nEOF",
            "cat <<'E OF'\nls | head\nE OF",
            "cat <<$F\nls | head\n$F",
            "cat <<E'OF'\nls | head\nEOF",
            "cat <<\\-EOF\nls | head\nEOF",
            # Unterminated: the body runs to the end of the command.
            "cat <<'EOF"
          ] do
        assert ShellTokens.split_last_stage(command) == :none,
               "expected #{inspect(command)} to have no top-level pipe"
      end

      # The body never becomes tokens — and neither does the delimiter, which
      # the heredoc scan consumes: `cat` is the command word, `<<` its operator,
      # and the newline ends the line. (Pre-existing shape, pinned so a change to
      # it is deliberate.)
      assert ShellTokens.tokenize("cat <<EOF\nls | head\nEOF") == [
               word: "cat",
               op: "<<",
               op: "\n"
             ]
    end

    test "a `<<` that is not a heredoc is an operator, not a delimiter" do
      # `cat << $file` has no delimiter word after the operator, and a bare `<<`
      # is a shift in arithmetic. Neither is a heredoc, so neither swallows what
      # follows.
      assert ShellTokens.split_last_stage("cat << $file") == :none
      assert ShellTokens.split_last_stage("echo $((1 << 2))") == :none
      assert ShellTokens.split_last_stage("echo ((1 << 2))") == :none
    end

    test "a comment is not code" do
      assert ShellTokens.split_last_stage("echo # | head") == :none
      assert ShellTokens.split_last_stage("echo # | head\nls") == :none
      # A trailing comment with no newline still ends the scan cleanly.
      assert ShellTokens.split_last_stage("ls # nothing after") == :none
      assert ShellTokens.tokenize("echo # | head") == [word: "echo"]
    end

    test "degenerate syntax does not become a wrong cut" do
      for command <- [
            "",
            "ls \\",
            ~s{echo "a\\},
            "cat <<'EOF"
          ] do
        assert ShellTokens.split_last_stage(command) == :none,
               "expected #{inspect(command)} to have no top-level pipe"
      end
    end
  end

  describe "command_words/1" do
    test "reports each simple command and whether a pipe feeds it" do
      assert ShellTokens.command_words(ShellTokens.tokenize("ls | head")) == [
               {"ls", false},
               {"head", true}
             ]

      # A file-descriptor prefix is not the command word, an assignment is
      # skipped, and a redirection's target is not a command.
      assert ShellTokens.command_words(ShellTokens.tokenize("ls | 2>/dev/null head")) == [
               {"ls", false},
               {"head", true}
             ]

      assert ShellTokens.command_words(ShellTokens.tokenize("VAR=x ls > out")) == [{"ls", false}]

      # A newline after a bare pipe continues the stage; `(head)` is the stage's
      # own command.
      assert ShellTokens.command_words(ShellTokens.tokenize("ls |\nhead")) == [
               {"ls", false},
               {"head", true}
             ]

      assert ShellTokens.command_words(ShellTokens.tokenize("ls | (head)")) == [
               {"ls", false},
               {"head", true}
             ]
    end
  end
end
