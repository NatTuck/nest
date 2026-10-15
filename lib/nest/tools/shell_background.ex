defmodule Nest.Tools.ShellBackground do
  @moduledoc """
  Rejects `shell-cmd` commands that ask for a *detached* background job.

  `setsid`, `nohup`, and an unquoted `&` are three signs that the caller expects
  a detached job. `shell-cmd` never detaches: the command runs under bwrap and
  the tool returns when it exits. So `sleep 60 &` returns immediately with empty
  output and exit 0, and the caller believes the job is running. That silent
  no-op is the bug — we do not do what the caller asked, and we do not say so.
  Rejecting the command is the fix.

  The check is unconditional, including when `background: true` is set. Inside
  bwrap there is no controlling terminal, so `nohup`/`setsid` cannot do what
  they are for; and with `background: true` a `&` still makes the staged script
  exit at once, so the job reports "exited 0" with no output — the same silent
  no-op. Keeping the check a pure function of the command string (independent of
  the `background` flag) is simpler to reason about and to test.

  This is a rejection, not a rewrite: the marker is never silently stripped for
  the caller. The message names the marker and points at the two alternatives —
  remove it to run in the foreground and wait, or pass `background: true` to run
  it as a managed job.

  ## Detection

  The command is tokenized by `Nest.Tools.ShellTokens`, then:

    * `setsid` and `nohup` are matched only as a stage's command word (compared
      by basename, so `/usr/bin/nohup` counts). `echo nohup`, `grep -e setsid
      file`, and `cat nohup.txt` are all allowed because the marker is an
      argument or a filename there, not the command word.
    * an unquoted `&` is matched as the background operator. Operators are
      recognised longest-first, so `&&`, `&>`, and `&>>` are single tokens and
      never match; `2>&1` tokenizes as the `>&` redirection operator and does not
      match either. A `&` inside single quotes, inside double quotes, in a `#`
      comment, or in a heredoc body is not an operator and does not match.

  A `&` that terminates a stage — at the end of a pipeline (`ls | sleep 1 &`),
  inside a subshell (`(sleep 1 &)`), or before a word (`cmd & wait`) — matches.

  Known limitations, the same wrapper and quoting gaps `Nest.Tools.ShellPipes`
  documents: the marker must be the stage's own command word, so `env setsid …`,
  `command nohup …`, and `xargs setsid` are not caught, and a marker after a
  shell keyword or in a brace group (`if …; then nohup …; fi`,
  `while …; do setsid …; done`, `{ nohup …; }`) is read as an argument rather
  than a command word. A marker that is quoted or nested inside another shell
  (`sh -c 'sleep 1 &'`) is not caught either, because the check is a pure
  function of the command string. It catches the direct spelling, which is the
  one models reach for. The `&` operator needs none of that: a bare `&` is
  caught wherever it appears, including inside those shapes.
  """

  alias Nest.Tools.ShellTokens

  # Commands whose purpose is to detach the job from the controlling terminal.
  @detach_commands ~w(setsid nohup)

  @doc """
  Returns `:ok`, or `{:error, message}` when `command` asks for a detached
  background job via `setsid`, `nohup`, or an unquoted `&`.
  """
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(command) when is_binary(command) do
    tokens = ShellTokens.tokenize(command)

    case marker(tokens) do
      nil -> :ok
      marker -> {:error, message(marker)}
    end
  end

  # A non-string command is `ShellPipes`'s to reject (it owns the type check);
  # there is nothing to detach in a value that is not a string.
  def check(_other), do: :ok

  defp marker(tokens) do
    detach_command(tokens) || background_operator(tokens)
  end

  # `setsid`/`nohup` only count as a stage's command word, so `echo nohup` and
  # `cat nohup.txt` stay allowed.
  defp detach_command(tokens) do
    tokens
    |> ShellTokens.command_words()
    |> Enum.find_value(fn {word, _piped?} ->
      base = Path.basename(word)
      if base in @detach_commands, do: base
    end)
  end

  # The scanner emits `&&`, `&>`, `&>>`, `>&`, and `<&` as their own tokens, so
  # a lone `{:op, "&"}` is exactly the background operator.
  defp background_operator(tokens) do
    if Enum.member?(tokens, {:op, "&"}), do: "&"
  end

  defp message(marker) do
    "Refused: `shell-cmd` never runs a command detached, but this command uses " <>
      "`#{marker}` to start a background job. Inside the sandbox the command " <>
      "runs in the foreground and the tool returns when it exits, so a detached " <>
      "job would appear to finish at once with no output. To run it in the " <>
      "foreground and wait for it, remove the marker; to run it as a managed " <>
      "job, pass `background: true` (manage it with shell-list, shell-wait, and " <>
      "shell-kill)."
  end
end
