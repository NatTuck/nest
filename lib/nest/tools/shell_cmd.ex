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
  - /dev: A fresh devtmpfs on a non-HPU host (overlays the read-only
    host /dev so device files like /dev/null are writable inside the
    sandbox). On an HPU host the host's `/dev` is re-bound with
    `--dev-bind` and the Habana log dir is bound read-write, so
    accelerator nodes are visible (see `Nest.Sandbox`).
  """

  require Logger

  alias Nest.Sandbox
  alias Nest.Sandbox.ShellJobs

  @default_timeout_ms 60_000
  @default_grace_ms 200

  @doc """
  Executes a shell command in a sandboxed environment.

  ## Options

    * `:timeout` - Maximum execution time in milliseconds (default: #{@default_timeout_ms})
    * `:stdin` - Binary data to send to the command's stdin over a real pipe (no base64) (default: "")
    * `:background` - when `true`, start the command as a background job
      owned by `Nest.Sandbox.ShellJobs` and return a job handle instead of
      waiting. Requires a `tmp_path` (the log lives under it). Additional
      opts: `:agent_key` (`{space_id, agent_name}`), `:agent_pid`, and
      `:grace_ms` (how long to wait for an immediate exit before reporting
      the job as running).

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
    stdin = normalize_stdin(Keyword.get(opts, :stdin))

    workspace = resolve_workspace(workspace_path)

    if tmp_path, do: File.mkdir_p!(tmp_path)

    {script, script_path} = stage_script(command, tmp_path)
    sandboxed_cmd = build_sandboxed_command(script_path, workspace, tmp_path, caps)

    if Keyword.get(opts, :background, false) do
      run_background(command, script, script_path, sandboxed_cmd, workspace, tmp_path, caps, opts)
    else
      Logger.info(
        "Executing sandboxed script #{script_path} in #{workspace}: #{truncate_log(command)}"
      )

      exec_staged(script, sandboxed_cmd, timeout, stdin, command, {workspace, tmp_path})
    end
  end

  # Run the staged script and remove it afterwards: it is only a transcript of
  # the command, and all the caller keeps is the output, so it goes on every
  # path - success, failure, timeout or crash.
  defp exec_staged(script, sandboxed_cmd, timeout, stdin, command, {workspace, tmp_path}) do
    case run_with_erlexec(sandboxed_cmd, timeout, stdin) do
      {:ok, exit_code, output} ->
        handle_exit_result(command, exit_code, output, workspace, tmp_path)

      {:error, reason} ->
        handle_startup_failure(command, reason, workspace, tmp_path)
    end
  after
    File.rm(script)
  end

  # Start the command as a background job and either report an immediate
  # exit (within the grace window) as a normal result, or hand the caller a
  # job handle. The job's script is removed by `ShellJobs` when the job ends.
  defp run_background(
         command,
         script,
         script_path,
         sandboxed_cmd,
         workspace,
         tmp_path,
         caps,
         opts
       ) do
    if is_nil(tmp_path) do
      File.rm(script)
      {:error, "Background jobs require a tmp directory"}
    else
      grace = Keyword.get(opts, :grace_ms, @default_grace_ms)
      agent_key = Keyword.get(opts, :agent_key, {:unknown, :unknown})

      Logger.info("Starting background shell job in #{workspace}: #{truncate_log(command)}")

      case ShellJobs.start_job(%{
             agent_key: agent_key,
             agent_pid: Keyword.get(opts, :agent_pid),
             command: command,
             bwrap: sandboxed_cmd,
             script_path: script_path,
             tmp_path: tmp_path,
             max_jobs: background_cap(caps)
           }) do
        {:ok, job_id, log_path} ->
          await_background_start(job_id, log_path, grace, agent_key, command, workspace, tmp_path)

        {:error, reason} ->
          File.rm(script)
          {:error, reason}
      end
    end
  end

  defp await_background_start(job_id, log_path, grace, agent_key, command, workspace, tmp_path) do
    ShellJobs.subscribe(agent_key, job_id, self())

    receive do
      {:shell_job_exit, ^job_id, code} ->
        {:ok, output} = ShellJobs.output(agent_key, job_id)
        handle_exit_result(command, code, output, workspace, tmp_path)
    after
      grace ->
        {:ok,
         "Started background job #{job_id} (log: #{log_path}). " <>
           "Use shell-list, shell-wait, or shell-kill to manage it."}
    end
  end

  # The per-agent background-job ceiling: `caps.shell.background` when set,
  # otherwise the always-on default of 1.
  defp background_cap(nil), do: 1

  defp background_cap(caps) do
    case get_in(caps, ["shell", "background"]) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 1
    end
  end

  defp handle_exit_result(_command, 0, "", _workspace, _tmp_path) do
    {:ok, "[Command executed successfully with no output]"}
  end

  defp handle_exit_result(_command, 0, output, _workspace, _tmp_path) do
    {:ok, output}
  end

  defp handle_exit_result(command, exit_code, output, workspace, tmp_path) do
    log_bwrap_failure(command, exit_code, output, workspace, tmp_path)
    {:error, "Exit code #{exit_code}:\n#{output}"}
  end

  defp handle_startup_failure(command, reason, workspace, tmp_path) do
    log_erlexec_start_failure(command, reason, workspace, tmp_path)
    {:error, "Execution failed: #{reason}"}
  end

  # Permanent diagnostic. bwrap exiting non-zero is the rare
  # path; under heavy parallel load it can fire intermittently
  # for reasons we don't fully understand yet. We want the
  # server log to capture every occurrence with enough detail
  # to diagnose a flake from the log alone.
  defp log_bwrap_failure(command, exit_code, output, workspace, tmp_path) do
    Logger.error(
      "ShellCmd.execute: bwrap exited non-zero " <>
        "(exit_code=#{exit_code}) for command=#{truncate_log(command)} " <>
        "workspace=#{workspace} tmp_path=#{tmp_path || "none"} " <>
        "output=#{inspect(output)}"
    )
  end

  defp log_erlexec_start_failure(command, reason, workspace, tmp_path) do
    Logger.error(
      "ShellCmd.execute: erlexec failed to start process " <>
        "(reason=#{inspect(reason)}) for command=#{truncate_log(command)} " <>
        "workspace=#{workspace} tmp_path=#{tmp_path || "none"}"
    )
  end

  # Write the command to a script file and run it with bash. With a tmp dir
  # (the usual case) the script lives in the directory the sandbox binds at
  # /tmp, so it is referenced as /tmp/<name> inside; without one it goes to the
  # host tmp dir and is read through the read-only root bind. Nest writes it as
  # the same uid the sandbox runs as, so both sides see the same file.
  defp stage_script(command, nil) do
    path = Path.join(System.tmp_dir!(), script_name())
    File.write!(path, command)
    {path, path}
  end

  defp stage_script(command, tmp_path) do
    host = Path.join(tmp_path, script_name())
    File.write!(host, command)
    {host, Path.join("/tmp", Path.basename(host))}
  end

  defp script_name do
    ".nest-cmd-#{System.unique_integer([:positive])}.sh"
  end

  defp normalize_stdin(nil), do: nil
  defp normalize_stdin(""), do: nil
  defp normalize_stdin(data), do: data

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
    build_bwrap_command(command, bwrap_args)
  end

  # Run the staged script with bash. Passing a file to the shell is what
  # removes the escaping layer: the command text never has to survive as one
  # quoted argv element.
  defp build_bwrap_command(script, bwrap_args) do
    bwrap_cmd = Enum.join(["bwrap" | bwrap_args], " ")
    "#{bwrap_cmd} /bin/bash '#{escape_shell(script)}'"
  end

  defp run_with_erlexec(command, timeout, stdin) do
    stdin_opt = if stdin, do: :stdin, else: {:stdin, :null}

    case :exec.run(
           to_charlist(command),
           [
             :stdout,
             :stderr,
             :monitor,
             stdin_opt,
             {:kill_timeout, 5000}
           ]
         ) do
      {:ok, _pid, os_pid} ->
        send_stdin(os_pid, stdin)

        # Buffers are IO lists (prepend in O(1)); `combine_output/1`
        # flattens to a single binary at the end.
        collect_output(os_pid, timeout, %{stdout: [], stderr: [], exit_code: nil})

      {:error, reason} ->
        {:error, "Failed to start process: #{inspect(reason)}"}
    end
  end

  # Feed staged stdin to the child, then close the pipe. A write to a process
  # that has already exited (or that never reads stdin) is not something the
  # caller cares about: the exit and the output are the result, so this
  # must never raise.
  defp send_stdin(_os_pid, nil), do: :ok

  defp send_stdin(os_pid, data) do
    try do
      :exec.send(os_pid, data)
    catch
      _kind, _reason -> :ok
    end

    :exec.send(os_pid, :eof)
  end

  defp collect_output(os_pid, timeout, acc) do
    receive do
      {:stdout, ^os_pid, data} ->
        collect_output(os_pid, timeout, append_stdout(acc, data))

      {:stderr, ^os_pid, data} ->
        collect_output(os_pid, timeout, append_stderr(acc, data))

      {:stop_chat, _from} ->
        handle_stop_chat(os_pid, acc)

      {:DOWN, _ref, :process, _pid, reason} ->
        handle_down(acc, reason)
    after
      timeout -> handle_timeout(os_pid, timeout, acc)
    end
  end

  defp append_stdout(acc, data),
    do: %{acc | stdout: [to_string(data) | acc.stdout]}

  defp append_stderr(acc, data),
    do: %{acc | stderr: [to_string(data) | acc.stderr]}

  # The user clicked Stop. `Lifecycle.stop_chat/2` forwards
  # `{:stop_chat, _}` to the tool worker before
  # `Process.exit(worker, :kill)` so we can clean up the bwrap
  # OS process explicitly. Without this, the `:erlexec` port
  # close + `:kill_timeout, 5000` cleanup is fragile (bwrap's
  # PID namespace isolation can leave the inner command
  # running).
  defp handle_stop_chat(os_pid, acc) do
    :exec.stop(os_pid)
    output = combine_output(acc) <> "\n[Command cancelled]"
    # 130 = 128 + SIGINT(2), the conventional shell cancellation
    # exit code (Ctrl-C).
    {:ok, 130, output}
  end

  defp handle_down(acc, reason) do
    {:ok, exit_code(reason), combine_output(acc)}
  end

  @doc false
  # erlexec reports the wait status the OS recorded: `:normal` for status 0 and
  # `{:exit_status, raw}` otherwise (a signal death included, so a killed
  # command is not a clean exit). `:exec.status/1` decodes the raw value.
  # Shared with `Nest.Sandbox.ShellJobs`, which decodes the same `:DOWN`
  # reason for background jobs.
  @spec exit_code(term()) :: integer()
  def exit_code(:normal), do: 0
  def exit_code({:exit_status, raw}), do: decode_status(:exec.status(raw))
  def exit_code(raw) when is_integer(raw), do: raw
  def exit_code(_other), do: 1

  defp decode_status({:status, code}), do: code

  # 128 + signo is the conventional shell spelling of a signal death.
  defp decode_status({:signal, signo, _core}) when is_integer(signo), do: 128 + signo
  defp decode_status({:signal, _name, _core}), do: 1

  defp handle_timeout(os_pid, timeout, acc) do
    :exec.stop(os_pid)
    output = combine_output(acc) <> "\n[Command timed out after #{timeout}ms]"
    {:ok, 1, output}
  end

  defp combine_output(acc) do
    output = acc.stdout |> Enum.reverse() |> IO.iodata_to_binary()

    if acc.stderr == [] do
      output
    else
      output <> "\n[stderr]\n" <> (acc.stderr |> Enum.reverse() |> IO.iodata_to_binary())
    end
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
