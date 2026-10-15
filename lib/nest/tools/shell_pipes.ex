defmodule Nest.Tools.ShellPipes do
  @moduledoc """
  Rejects `shell-cmd` commands that pipe a command's output into `head` or
  `tail`.

  Models habitually pipe a command's output into `head`/`tail`, most often on
  long-running commands, which discards almost all of the output. It does not
  help with context management — the `shell-cmd` tool already caps its result
  size and substitutes a path-and-head summary when a result is too large — and
  it defeats output streaming. The property that matters is *truncate vs
  select*: `head` and `tail` truncate, discarding the head or tail of the
  output, which is exactly what the tool's own result cap already handles.
  `grep` selects; it is a legitimate filter, and a model that genuinely needs to
  filter output would otherwise have to write a script to get it. So `grep` is
  allowed, and there is deliberately no escape hatch for `head`/`tail`.

  The rule used to cover `grep` too, and it was already leaky: `rg`, `awk`, and
  `sed` were never in the list, so `| rg foo` and `| sed -n '1,20p'` (an allowed
  `head`) both passed, while the common spelling of the same intent — `| grep
  foo` — was refused. Refusing only `head` and `tail` keeps the one property
  that justifies the filter and stops punishing the ordinary filter.

  ## Detection

  The command is tokenized by `Nest.Tools.ShellTokens`, then walked to find the
  command word of every pipeline stage: the word that follows an unquoted `|`
  or `|&`, after skipping `NAME=value` assignments and redirection targets. A
  stage whose command word is `head` or `tail` (compared by basename, so
  `/usr/bin/head` counts) is rejected.

  The scanner tracks single quotes, double quotes, backslash escapes, `#`
  comments, and heredoc bodies, so none of these is a false positive:

      head -1 file          # head is not piped to
      tail -1 file          # tail is not piped to
      cat head.txt          # head is a filename
      echo "| head"         # inside double quotes
      echo 'a | tail b'     # inside single quotes
      cat <<'EOF'           # heredoc body — the "write a script" workaround
      ls | head
      EOF

  `||` (logical or) and `&&`/`;`/`&` are not pipes and never match. A newline or
  an opening paren while a command is still expected does not end the stage —
  bash reads

      ls |
      head

  as `ls | head`, and `ls | (head)` pipes into the subshell's first command.

  Command substitution is inspected unless it sits inside double quotes: the
  contents of a backtick substitution and of an unquoted `$(...)` are scanned
  like ordinary shell code, so `` `ls | head` `` and `$(ls | head)` are
  rejected. A substitution inside double quotes (`"$(...)"`) is not.

  Known limitations: the pager must be the stage's own command word, so one
  reached indirectly is not caught — behind a wrapper (`env`, `nice`, `sudo`,
  `command`, `timeout`, `stdbuf`, `busybox`, or `sh -c '...'`), inside a brace
  group (`ls | { head; }`), or in an `if`/`case` stage. `ls | xargs head` is
  likewise not caught, and that is a real miss rather than a harmless one:
  `xargs` still discards output (`ls | xargs -n1 head -1` truncates each listed
  command to one line).

  There is one known false positive: an unquoted `|` in a `case` pattern list
  separates alternative patterns rather than piping, but the walk does not
  track command-word position, so it cannot tell the two apart and

      case $x in head|tail) echo ok;; esac

  is refused. Quote or avoid the pattern separator to work around it. (`awk
  /head|tail/ file` is refused for the same reason, but there it is correct:
  bash tokenizes the unquoted `|` as a pipe and tries to run `tail/`, so the
  regex must be quoted — `awk '/head|tail/' file` is allowed.)
  """

  alias Nest.Tools.ShellTokens

  # Command names whose pipeline use truncates output.
  @pager_commands ~w(head tail)

  @doc """
  Returns `:ok`, or `{:error, message}` when `command` is not a string or pipes
  output into `head` or `tail`.
  """
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(command) when is_binary(command) do
    case piped_pager(command) do
      nil -> :ok
      name -> {:error, message(name)}
    end
  end

  # The tool's schema only checks that the `command` key is present, so a
  # non-string value (a list, a number) reaches here. Reject it with the same
  # shape as the `timeout` validation rather than letting `ShellCmd` crash on
  # `String.length/1` and leak a staged script.
  def check(other), do: {:error, invalid_command_message(other)}

  # The pager must be the command word of a stage fed by a pipe: `head -1 file`
  # is fine (it is not piped *into*), but `ls | head` is not.
  defp piped_pager(command) do
    command
    |> ShellTokens.tokenize()
    |> ShellTokens.command_words()
    |> Enum.find_value(fn
      {word, true} -> pager_name(word)
      {_word, false} -> nil
    end)
  end

  defp pager_name(word) do
    base = Path.basename(word)
    if base in @pager_commands, do: base
  end

  defp message(name) do
    "Refused: `shell-cmd` will not pipe command output into `#{name}`. " <>
      "Piping to head or tail discards most of the command's output, and " <>
      "the tool already limits how much it returns: an oversized result is saved " <>
      "to a scratch file and summarised by its path and head lines. " <>
      "Re-run the command without the pipe."
  end

  defp invalid_command_message(other) do
    "Invalid `command` argument: expected a string, got: " <> inspect(other) <> "."
  end
end
