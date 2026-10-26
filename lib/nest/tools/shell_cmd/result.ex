defmodule Nest.Tools.ShellCmd.Result do
  @moduledoc """
  How a finished shell command becomes the tool's return value.

  One place for the three shapes a command's end can take — success, success
  with no output, and failure — because both halves of `Nest.Tools.ShellCmd` use
  them: the foreground path (`exec_staged/7`) and the background one
  (`Nest.Tools.ShellCmd.Background`, which reports a command that exits inside
  its grace window as an ordinary result). Split out for the source-file cap.

  The failure arm is also where the operator's log line is written
  (`Nest.Tools.ShellCmd.Diagnostics`), so a command cannot fail in one path and
  not be logged in it.
  """

  alias Nest.Sandbox.Mounts
  alias Nest.Tools.ShellCmd.Diagnostics

  @doc """
  The result for a command that ran and exited with `exit_code` and `output`.

  An empty success keeps its placeholder — the agent asked for a command, and
  "nothing" is a worse answer than a sentence saying so.
  """
  @spec from_exit(String.t(), non_neg_integer(), binary(), Mounts.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def from_exit(_command, 0, "", _mounts),
    do: {:ok, "[Command executed successfully with no output]"}

  def from_exit(_command, 0, output, _mounts), do: {:ok, output}

  def from_exit(command, exit_code, output, mounts) do
    Diagnostics.sandbox_failure(command, exit_code, output, mounts)
    {:error, "Exit code #{exit_code}:\n#{output}"}
  end

  @doc "The result for a command whose process never started."
  @spec from_start_failure(String.t(), term(), Mounts.t()) :: {:error, String.t()}
  def from_start_failure(command, reason, mounts) do
    Diagnostics.start_failure(command, reason, mounts)
    {:error, "Execution failed: #{reason}"}
  end
end
