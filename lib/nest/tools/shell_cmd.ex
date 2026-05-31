defmodule Nest.Tools.ShellCmd do
  @moduledoc """
  Sandboxed shell command execution using bwrap and erlexec.

  This module provides sandboxed command execution for agent tools.
  Commands run in an isolated environment with:
  - Network isolation (--unshare-net)
  - Read-only filesystem access (except workspace)
  - Process namespace isolation
  - Proper cleanup on exit

  ## Programmer Build Mode Profile

  Current sandbox profile:
  - Network: Disabled
  - Filesystem read: Entire host (read-only)
  - Filesystem write: Workspace directory only
  """

  require Logger

  @default_timeout_ms 60_000

  @doc """
  Executes a shell command in a sandboxed environment.

  ## Options

    * `:timeout` - Maximum execution time in milliseconds (default: #{@default_timeout_ms})

  ## Returns

    * `{:ok, output}` - Command completed successfully
    * `{:error, output}` - Command failed or was terminated

  Both success and failure return the command output, which should be
  displayed as a message in the chat UI.
  """
  @spec execute(String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(command, workspace_path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    # Validate workspace exists
    workspace = resolve_workspace(workspace_path)

    # Build the sandboxed command
    sandboxed_cmd = build_sandboxed_command(command, workspace)

    Logger.info("Executing sandboxed command in #{workspace}: #{truncate_log(command)}")

    # Execute via erlexec
    case run_with_erlexec(sandboxed_cmd, timeout) do
      {:ok, exit_code, output} when exit_code == 0 ->
        {:ok, output}

      {:ok, exit_code, output} ->
        {:error, "Exit code #{exit_code}:\n#{output}"}

      {:error, reason} ->
        {:error, "Execution failed: #{reason}"}
    end
  end

  @doc """
  Builds the bwrap arguments for the programmer build mode sandbox profile.

  ## Profile Settings

    * Network: Disabled
    * Read access: Entire filesystem (read-only)
    * Write access: Workspace directory only
  """
  @spec build_bwrap_args(String.t()) :: [String.t()]
  def build_bwrap_args(workspace_path) do
    [
      # Namespace isolation
      "--unshare-all",
      "--die-with-parent",
      "--new-session",
      # Basic filesystem
      "--proc",
      "/proc",
      "--dev",
      "/dev",
      # Read-only root filesystem
      "--ro-bind",
      "/",
      "/",
      # Read-write workspace
      "--bind",
      workspace_path,
      workspace_path,
      # Network isolation
      "--unshare-net",
      # Working directory
      "--chdir",
      workspace_path
    ]
  end

  # Private functions

  defp resolve_workspace(nil) do
    # Use a temporary directory if no workspace specified
    System.tmp_dir!()
  end

  defp resolve_workspace(path) do
    if File.dir?(path) do
      path
    else
      raise "Workspace directory does not exist: #{path}"
    end
  end

  defp build_sandboxed_command(command, workspace_path) do
    bwrap_args = build_bwrap_args(workspace_path)
    bwrap_cmd = Enum.join(["bwrap" | bwrap_args], " ")
    shell_escaped = escape_shell(command)
    "#{bwrap_cmd} /bin/sh -c '#{shell_escaped}'"
  end

  defp run_with_erlexec(command, timeout) do
    # Start erlexec process
    case :exec.run(
           to_charlist(command),
           [
             :stdout,
             :stderr,
             :monitor,
             {:kill_timeout, 5000}
           ]
         ) do
      {:ok, _pid, os_pid} ->
        collect_output(os_pid, timeout, %{stdout: "", stderr: "", exit_code: nil})

      {:error, reason} ->
        {:error, "Failed to start process: #{inspect(reason)}"}
    end
  end

  defp collect_output(os_pid, timeout, acc) do
    receive do
      {:stdout, ^os_pid, data} ->
        acc = %{acc | stdout: acc.stdout <> to_string(data)}
        collect_output(os_pid, timeout, acc)

      {:stderr, ^os_pid, data} ->
        acc = %{acc | stderr: acc.stderr <> to_string(data)}
        collect_output(os_pid, timeout, acc)

      {:DOWN, _ref, :process, _pid, :normal} ->
        output = combine_output(acc)
        {:ok, acc.exit_code || 0, output}

      {:DOWN, _ref, :process, _pid, reason} ->
        output = combine_output(acc)
        exit_code = if is_integer(reason), do: reason, else: 1
        {:ok, exit_code, output}
    after
      timeout ->
        :exec.stop(os_pid)
        output = combine_output(acc) <> "\n[Command timed out after #{timeout}ms]"
        {:ok, 1, output}
    end
  end

  defp combine_output(acc) do
    output = acc.stdout

    output =
      if acc.stderr != "" do
        output <> "\n[stderr]\n" <> acc.stderr
      else
        output
      end

    output
  end

  defp escape_shell(command) do
    # Escape single quotes by ending the quote, adding escaped quote, resuming quote
    command
    |> String.replace("'", "'\\''")
  end

  defp truncate_log(command) do
    if String.length(command) > 100 do
      String.slice(command, 0, 100) <> "..."
    else
      command
    end
  end
end
