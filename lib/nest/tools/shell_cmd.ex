defmodule Nest.Tools.ShellCmd do
  @moduledoc """
  Sandboxed shell command execution using bwrap and erlexec.

  This module provides sandboxed command execution for agent tools.
  Commands run in an isolated environment with:
  - Network isolation (configurable via caps)
  - Read-only filesystem access (except workspace and /tmp when tmp_path is provided)
  - A fresh devtmpfs at /dev, so shell redirects like `> /dev/null` and
    `2>/dev/null` work as expected
  - Process namespace isolation
  - Proper cleanup on exit

  ## Sandbox Profile

  The bwrap profile is determined by the `caps` map (see `Nest.Sandbox`).
  When `caps` is `nil` (legacy callers), the default profile is used:
  - Network: Disabled
  - Filesystem read: Entire host (read-only)
  - Filesystem write: Workspace directory (at original path) and /tmp (when tmp_path provided)
  - /dev: Fresh devtmpfs (overlays the read-only host /dev so device files
    like /dev/null are writable inside the sandbox)
  """

  require Logger

  alias Nest.Sandbox

  @default_timeout_ms 60_000

  @doc """
  Executes a shell command in a sandboxed environment.

  ## Options

    * `:timeout` - Maximum execution time in milliseconds (default: #{@default_timeout_ms})
    * `:stdin` - Binary data to send to stdin via base64 encoding (default: "")

  ## Returns

    * `{:ok, output}` - Command completed successfully
    * `{:error, output}` - Command failed or was terminated (bwrap
      returning "Permission denied" surfaces as `{:error, "Exit code N: ..."}`)

  Both success and failure return the command output, which should be
  displayed as a message in the chat UI.

  Pass `nil` for `caps` to use the default profile (no network, full
  host read-only, workspace + tmp writable). This is preserved for
  back-compat with callers that haven't been migrated.
  """
  @spec execute(String.t(), String.t() | nil, String.t() | nil, map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(command, workspace_path, tmp_path \\ nil, caps \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    stdin = Keyword.get(opts, :stdin, "")

    # Validate workspace exists
    workspace = resolve_workspace(workspace_path)

    # If stdin is provided, embed it via base64 to avoid stdin redirection issues
    final_command =
      if stdin != "" do
        # Encode stdin content as base64 and pipe through base64 -d
        encoded = Base.encode64(stdin)
        # Escape single quotes in the base64 string for shell safety
        escaped = String.replace(encoded, "'", "'\\''")
        "printf '%s' '#{escaped}' | base64 -d | #{command}"
      else
        command
      end

    # Build the sandboxed command
    sandboxed_cmd = build_sandboxed_command(final_command, workspace, tmp_path, caps)

    Logger.info("Executing sandboxed command in #{workspace}: #{truncate_log(command)}")

    # Execute via erlexec
    case run_with_erlexec(sandboxed_cmd, timeout) do
      {:ok, exit_code, output} when exit_code == 0 ->
        # Return placeholder if output is empty so the LLM gets
        # feedback that the command succeeded but produced nothing.
        if output == "" do
          {:ok, "[Command executed successfully with no output]"}
        else
          {:ok, output}
        end

      {:ok, exit_code, output} ->
        {:error, "Exit code #{exit_code}:\n#{output}"}

      {:error, reason} ->
        {:error, "Execution failed: #{reason}"}
    end
  end

  @doc """
  Builds the bwrap arguments for the sandbox.

  When `caps` is `nil`, uses `Sandbox.default_caps/0` (the legacy
  hardcoded profile). Otherwise builds args from the provided caps.

  Arg ordering: `--dev /dev` must come AFTER `--ro-bind / /` (handled
  in `Nest.Sandbox`). If it comes first, the subsequent read-only
  bind of the host root shadows the devtmpfs, leaving the sandbox
  with a read-only /dev where even opening /dev/null for writing
  fails with "Permission denied".
  """
  @spec build_bwrap_args(String.t(), String.t() | nil, map() | nil) :: [String.t()]
  def build_bwrap_args(workspace_path, tmp_path \\ nil, caps \\ nil) do
    effective_caps = caps || Sandbox.default_caps()
    {:ok, args} = Sandbox.build(effective_caps, workspace_path, tmp_path)
    args
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

  defp build_sandboxed_command(command, workspace_path, tmp_path, caps) do
    bwrap_args = build_bwrap_args(workspace_path, tmp_path, caps)
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
