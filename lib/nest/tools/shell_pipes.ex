defmodule Nest.Tools.ShellPipes do
  # Before the moduledoc: the docs interpolate it.
  @long_command_ms 30_000

  @moduledoc """
  Refuses a piped `shell-cmd` command that can run longer than 30 seconds.

  ## The rule

  Two cases, no exceptions:

    * the command's wall-clock bound is #{@long_command_ms} milliseconds or less —
      the command is accepted exactly as written, pipe and all;
    * otherwise any top-level pipe is refused.

  A pipe throws away output this tool would have kept (it caps the result and
  files anything large), and a run that long is expensive to repeat for the part
  that was filtered away. The refusal names the alternative: write a script that
  manages its own log, and run the script.

  `background: true` is the long case — a job's `timeout` is ignored, so its
  bound is unbounded. An omitted `timeout` is the tool's default
  (`ShellCmd.default_timeout_ms/0`, 60 seconds), so it is the long case too:
  omitting it must not be the way around the rule.

  ## Why a refusal and not a rewrite

  This module used to *remove* a trailing truncating stage and file the complete
  output. A rewrite the model does not expect is a rewrite it works around — a
  filter anywhere but last, or `| cat` — and the warning it got back was ignored
  (#200, #205). A refusal cannot be worked around, and it says what to do
  instead.

  ## Detection

  `ShellTokens.split_last_stage/1` reports only a **top-level** pipe, so a pipe
  inside quotes, a command substitution, a subshell or a heredoc *body* is not
  this command's own pipeline. A heredoc piped onward (`cat <<EOF | head`) is a
  real pipe and is treated like any other. The wrapper gaps the other command
  checks document apply here too: `xargs sh -c 'a | b'` is not seen.
  """

  alias Nest.Tools.ShellTokens

  @doc "The wall-clock bound, in milliseconds, at or below which pipes are allowed."
  @spec long_command_ms() :: pos_integer()
  def long_command_ms, do: @long_command_ms

  @doc """
  `:ok`, or `{:error, message}` when `command` pipes its output and may run for
  longer than #{@long_command_ms} milliseconds.

  `timeout_ms` is the command's effective bound — the caller resolves the
  default, so this module never has to know it.
  """
  @spec check(term(), non_neg_integer(), boolean()) :: :ok | {:error, String.t()}
  def check(command, timeout_ms, background?) when is_binary(command) do
    if (background? or timeout_ms > @long_command_ms) and piped?(command),
      do: {:error, refusal()},
      else: :ok
  end

  def check(other, _timeout_ms, _background?), do: {:error, invalid_command_message(other)}

  defp piped?(command), do: ShellTokens.split_last_stage(command) != :none

  @doc """
  The refusal a piped command over the bound gets.

  It names a *script* rather than a compound command: a one-liner with `;` chains
  is the same shape the model already misuses, and the log it writes has to be
  somewhere it can read afterwards.
  """
  @spec refusal() :: String.t()
  def refusal do
    "This command pipes output and may run for more than #{div(@long_command_ms, 1000)} " <>
      "seconds, so it was not run. A pipe throws away output `shell-cmd` keeps, and a " <>
      "run that long is expensive to repeat for the part you filtered away.\n\n" <>
      "Write a script and run it (`file-write`, then `shell-cmd sh run.sh`):\n\n" <>
      "    ./build.sh > /tmp/<your-name>/build.log 2>&1\n" <>
      "    status=$?\n" <>
      "    tail -n 20 /tmp/<your-name>/build.log\n" <>
      "    exit $status\n\n" <>
      "The log keeps every line; the script decides what comes back. To watch a job " <>
      "instead, use `background: true` with `shell-list` / `shell-wait`. If the command " <>
      "is really short, pass `timeout: #{div(@long_command_ms, 1000)}` or less and the " <>
      "pipe runs as written."
  end

  defp invalid_command_message(other) do
    "Invalid `command` argument: expected a string, got: " <> inspect(other) <> "."
  end
end
