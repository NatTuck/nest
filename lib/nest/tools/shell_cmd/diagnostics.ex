defmodule Nest.Tools.ShellCmd.Diagnostics do
  @moduledoc """
  The operator log lines for a shell command that failed.

  Split out of `Nest.Tools.ShellCmd` for the source-file cap, and because these
  are the *operator's* lines rather than the command's: nothing here reaches the
  agent, which gets the `{:error, "Exit code N: …"}` its caller builds.

  The failure line is permanent. The sandbox command exiting non-zero is the rare
  path; under heavy parallel load it can fire intermittently for reasons we don't
  fully understand yet, so the server log has to capture every occurrence with
  enough detail to diagnose a flake from the log alone.

  Printing the directories is deliberate: a flake is diagnosed by asking *which*
  directories the failing invocation was given, and the agent's own
  `/tmp/<agent-name>/…` spelling is not what the backend was handed. None of it
  reaches the agent, so it is not the leak the sandbox-spelling rule is about.

  The backend's display name leads the line, so a `"docker"` or `"none"` space's
  failure is not reported as bwrap's. `Nest.Sandbox.Backend.Bwrap` answers
  `"bwrap"`, which is why this reads exactly as it did when bwrap was the only
  backend.
  """

  require Logger

  alias Nest.Sandbox.{Backend, Mounts}

  @doc """
  The command as the operator log renders it: one line, at most 100 characters.

  Shared with `Nest.Tools.ShellCmd`'s two "starting" lines, so a command is
  abbreviated the same way whether it is starting or failing.
  """
  @spec truncate(String.t()) :: String.t()
  def truncate(command) do
    if String.length(command) > 100 do
      String.slice(command, 0, 100) <> "..."
    else
      command
    end
  end

  @doc "Log a sandbox command that ran and exited non-zero."
  @spec sandbox_failure(String.t(), integer(), binary(), Mounts.t()) :: :ok
  def sandbox_failure(command, exit_code, output, mounts) do
    Logger.error(
      "ShellCmd.execute: #{Backend.display_name(mounts)} exited non-zero " <>
        "(exit_code=#{exit_code}) for command=#{truncate(command)} " <>
        "workspace=#{Mounts.workspace(mounts) || "none"} " <>
        "scratch=#{Mounts.scratch(mounts) || "none"} " <>
        "output=#{inspect(output)}"
    )
  end

  @doc "Log a command whose process never started."
  @spec start_failure(String.t(), term(), Mounts.t()) :: :ok
  def start_failure(command, reason, mounts) do
    Logger.error(
      "ShellCmd.execute: erlexec failed to start process " <>
        "(reason=#{inspect(reason)}) for command=#{truncate(command)} " <>
        "workspace=#{Mounts.workspace(mounts) || "none"} " <>
        "scratch=#{Mounts.scratch(mounts) || "none"}"
    )
  end
end
