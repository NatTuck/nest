defmodule Nest.Tools.ShellTokensTest do
  @moduledoc """
  The tokenizer's own edges, and the two questions callers ask of a command:
  `piped?/1` (does it have a top-level pipe?) and `command_words/1` (which words
  are command words, and which stages are fed by a pipe?).

  `tokenize/1` is pinned alongside, because two callers depend on its output
  shape (`command_words/1` for `ShellBackground.check/1`, and the words
  `ShellBackground` compares): the scanner's internal token shape must not leak
  into the token stream.
  """

  use ExUnit.Case, async: true

  alias Nest.Tools.ShellTokens

  describe "piped?/1" do
    test "a top-level pipe is a pipe, whatever stage follows it" do
      for command <- [
            "ls | head",
            "ls|head",
            "ls | grep x | head",
            "ls |& head",
            # The pipe is top-level and the stage after it is a subshell.
            "ls | (head)",
            "cd /x\nls | head",
            "ls |\nhead",
            # A pipe after a heredoc's terminator is the command's own.
            "cat <<EOF\nls\nEOF\n| head"
          ] do
        assert ShellTokens.piped?(command), "expected #{inspect(command)} to be piped"
      end
    end

    test "everything that is not the command's own top-level pipe is not one" do
      for command <- [
            "head -1 file",
            "",
            "ls",
            # `ls \| head` runs `ls` with two arguments; bash never pipes it.
            "ls \\| head",
            "ls || head",
            ~s{echo "a | head"},
            "echo 'a | b'",
            ~s{echo "it's 'a | b'"},
            "echo $(ls | head)",
            "`ls | head`",
            "(ls | head)",
            "cd /x\nls",
            "cat << $file",
            "echo $((1 << 2))",
            "echo ((1 << 2))",
            "echo # | head",
            "echo # | head\nls",
            "ls # nothing after",
            "ls \\",
            ~s{echo "a\\},
            # A heredoc body is not code, whichever way its delimiter is quoted.
            "cat <<EOF\nls | head\nEOF",
            "cat <<'EOF'\nls | head\nEOF",
            "cat <<-EOF\n\tls | head\n\tEOF",
            "cat <<\\EOF\nls | head\nEOF",
            "cat <<'E OF'\nls | head\nE OF",
            "cat <<$F\nls | head\n$F",
            "cat <<E'OF'\nls | head\nEOF",
            "cat <<\\-EOF\nls | head\nEOF",
            "cat <<'EOF",
            # bash does not read `EOF | head` as a terminator, so that pipe is in
            # the body.
            "cat <<EOF\nls\nEOF | head"
          ] do
        refute ShellTokens.piped?(command), "expected #{inspect(command)} not to be piped"
      end
    end
  end

  describe "tokenize/1" do
    test "words and operators only, with none of the scanner's own state" do
      # The scanner's operators carry the in-backtick flag; the public token must
      # not. `command_words/1` and `ShellBackground.check/1` both read this shape.
      # Quotes are removed from a word. This is load-bearing for the *other*
      # consumer: `ShellBackground.check/1` compares command words to
      # `setsid`/`nohup`, so a quoted marker is only caught because the quotes
      # are gone. Without this line no test pins quote removal at all — the
      # `piped?/1` verdicts do not depend on the word text.
      assert ShellTokens.tokenize("'setsid' sleep 1") == [
               word: "setsid",
               word: "sleep",
               word: "1"
             ]

      assert ShellTokens.tokenize("ls \\| head") == [word: "ls", word: "|", word: "head"]
      assert ShellTokens.tokenize("ls || head") == [word: "ls", op: "||", word: "head"]
      assert ShellTokens.tokenize("`ls | head`") == [word: "ls", op: "|", word: "head"]

      assert ShellTokens.tokenize("cat <<EOF\nls | head\nEOF") == [
               word: "cat",
               op: "<<",
               op: "\n"
             ]
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
