defmodule Nest.Tools.ShellPipes do
  @moduledoc """
  Rewrites a `shell-cmd` command whose **last** pipeline stage throws output
  away, so the output survives and the model is told where it went.

  Models habitually pipe a command's output into `head`/`tail` — most often on a
  long-running command — which discards almost all of it before the tool ever
  sees it. The tool already caps what it returns, and an oversized result is
  saved to a scratch file and summarised by its path, so a truncating pipe buys
  nothing: it destroys output the tool would have kept. Refusing the command
  (which this module used to do) punished the model without producing the
  output; instead the stage is *removed*, the command runs unfiltered, the
  complete output is filed in the agent's scratch directory, and the result is a
  warning naming the file. Nothing is ever refused.

  ## The rule

  A stage is removed only when it is the **last** stage of the command, and it
  is one of:

    * `head` — always (`head -n 5`, `head -c 100`, `head -20`);
    * `tail` — always;
    * `sed` — only when its script is a pure line range, i.e. the head/tail
      replica: `-n '1,50p'`, `-n '50,100p'`, `-n '5p'`, `-n '$p'`, `1,50d`. A
      substitution (`s/a/b/`), an in-place edit, `-f script`, or a script with
      more than one command leaves the stage alone.

  Never touched: `grep`, `awk`, any form naming a file operand (`sed -n '1,5p'
  file`, `head -5 file`), and anything that is not the final stage (`ls | head |
  wc -l`, `ls | head && echo done`). A `head`/`tail` stage whose arguments
  include a bare word is a file operand and is left alone; a `sed` stage may
  name only its `-n` flag and its script.

  ## Detection

  The command is tokenized by `Nest.Tools.ShellTokens`, which is quote- and
  heredoc-aware, so `echo "a | head"` has no pipe token and is untouched. The
  stage boundary comes from `ShellTokens.stage_spans/1`: only top-level `|`/`|&`
  separate stages, so a pipe inside a subshell or a command substitution is not
  the command's own boundary.

  A command that declares a **heredoc** is left alone: its body starts on the
  line after its `<<`, which is after the pipe when the two share a line
  (`cat <<EOF | head`), so cutting at the pipe would take the body with the
  stage and leave `cat <<EOF` reading nothing.

  Known limitations, all of them "left alone" rather than "mis-rewritten": a
  truncator behind a wrapper (`ls | xargs head`, `ls | env head`, `ls | { head;
  }`) is not the stage's own command word, so it is not seen.
  """

  alias Nest.Tools.ShellTokens

  # Commands whose pipeline use throws output away.
  @pagers ["head", "tail"]

  # `sed`'s head/tail replicas: one address or address range, then `p` or `d`.
  # An address is a line number or `$` (the last line).
  @address "(?:\\d+|\\$)"
  @print_range Regex.compile!("^#{@address}(?:,#{@address})?p$")
  @delete_range Regex.compile!("^#{@address}(?:,#{@address})?d$")

  @doc """
  The command to run instead of `command`, and the name of the stage that was
  removed: `{:ok, {command_without_it, "head" | "tail" | "sed"}}`. `{:ok, nil}`
  when there is nothing to remove.

  A non-string `command` is `{:error, message}` — the tool's schema only checks
  that the key is present, so a list or a number reaches here and must not crash
  `ShellCmd`.
  """
  @spec truncation(term()) :: {:ok, nil | {String.t(), String.t()}} | {:error, String.t()}
  def truncation(command) when is_binary(command), do: {:ok, trailing_truncator(command)}

  def truncation(other), do: {:error, invalid_command_message(other)}

  # The judge agent named in the warning below is a **fiction**, deliberately:
  # nothing is queued for review and no process evaluates anything. It is a
  # deterrent, and it works because the model cannot check it — which is exactly
  # why the wording must not be softened. "We may review your commands" is not a
  # deterrent; "if this behaviour is repeated" is what makes it one. Do not make
  # it true, and do not water it down.
  #
  # Every other sentence is a claim this code keeps, so each is qualified to the
  # case it is true of: the file holds the complete output (the caller only
  # sends this warning after a successful write), and `max_result_tokens` is
  # described as filing the output *when it overflows* — the overflow path is
  # what saves it, and a result that fits inline is returned whole instead. It
  # chooses the size in **both** directions (it is a target, not a cap), which
  # is why the sentence says "choose the size" rather than "ask for less".
  @doc """
  The warning `shell-cmd` returns in place of an output it filed.

  `stage` is the removed stage's name and `path` the file holding the complete
  output. The caller must have written that file: this sentence is a promise
  about it.
  """
  @spec warning(String.t(), String.t()) :: String.t()
  def warning(stage, path) do
    "Your command was piped into `#{stage}` and that stage was removed. " <>
      "The complete output is in #{path} — read it. " <>
      "Do not throw away output. " <>
      "If you need to choose the size, use the tool's `max_result_tokens` " <>
      "argument — that is the supported way to decide how much comes back, and " <>
      "when the result is large enough to overflow, the complete output is " <>
      "still saved to a file for you to read. " <>
      "Do not use any substitutions: no `| head`, no `| tail`, no `| sed`, no " <>
      "filtering of any kind. " <>
      "If this behaviour is repeated, every command you run will be evaluated " <>
      "for cheating by a judge agent."
  end

  # The command with its trailing truncating stage cut off, or `nil`.
  defp trailing_truncator(command) do
    tokens = ShellTokens.tokenize(command)

    with false <- heredoc?(tokens),
         {prefix, stage} when prefix != "" <- ShellTokens.split_last_stage(command),
         {:ok, name} <- truncator(stage_tokens(stage)) do
      {prefix, name}
    else
      _no_truncation -> nil
    end
  end

  # A heredoc's body starts after its `<<` line, so it can sit after the pipe the
  # cut would be made at (`cat <<EOF | head`). Leave the whole command alone
  # rather than cut a body away from the command that reads it.
  defp heredoc?(tokens), do: Enum.any?(tokens, &match?({:op, op} when op in ["<<", "<<-"], &1))

  defp stage_tokens(stage), do: stage |> ShellTokens.tokenize() |> drop_trailing_newlines()

  # `ls | head` + a trailing newline (and any trailing blank lines or comment)
  # is still a single-stage tail; those tokens are not a following command.
  defp drop_trailing_newlines(tokens) do
    tokens |> Enum.reverse() |> Enum.drop_while(&match?({:op, "\n"}, &1)) |> Enum.reverse()
  end

  defp truncator([{:word, command} | args]) do
    if Enum.all?(args, &match?({:word, _}, &1)) do
      name = Path.basename(command)
      args = for {:word, arg} <- args, do: arg

      cond do
        name in @pagers and pager_args?(args) -> {:ok, name}
        name == "sed" and sed_range?(args) -> {:ok, "sed"}
        true -> nil
      end
    end
  end

  defp truncator(_tokens), do: nil

  # `head -n 5`, `head -c 100`, `head -20`, `head --lines=5`. A bare word is a
  # *file operand* (`head -5 file`), which makes `head` read that file instead of
  # the pipe, so the stage is left alone.
  defp pager_args?(args), do: pager_args?(args, false)

  defp pager_args?([], _value_expected?), do: true

  defp pager_args?([_value | rest], true), do: pager_args?(rest, false)

  defp pager_args?([arg | rest], false) do
    cond do
      arg in ["-n", "-c", "--lines", "--bytes"] -> pager_args?(rest, true)
      String.starts_with?(arg, "-") -> pager_args?(rest, false)
      true -> false
    end
  end

  # Only `-n` (in its three spellings) may be named: `-i` is an in-place edit,
  # `-f` reads the script from a file, and `-e` names a second command. The
  # script is the only other argument, so a file operand is refused too.
  defp sed_range?(args) do
    {flags, rest} = Enum.split_while(args, &String.starts_with?(&1, "-"))

    if Enum.all?(flags, &(&1 in ["-n", "--quiet", "--silent"])) do
      case rest do
        # Without `-n`, `p` prints every line *and* the range, so it is not a
        # truncator; `d` deletes the range either way.
        [script] -> (quiet?(flags) and print_range?(script)) or delete_range?(script)
        _other -> false
      end
    else
      false
    end
  end

  defp quiet?(flags), do: flags != []

  defp print_range?(script), do: Regex.match?(@print_range, script)
  defp delete_range?(script), do: Regex.match?(@delete_range, script)

  defp invalid_command_message(other) do
    "Invalid `command` argument: expected a string, got: " <> inspect(other) <> "."
  end
end
