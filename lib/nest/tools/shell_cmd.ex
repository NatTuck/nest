defmodule Nest.Tools.ShellCmd do
  @moduledoc """
  Sandboxed shell command execution through the space's sandbox backend.

  This module provides command execution for agents. Which environment a
  command runs in is `Nest.Sandbox.Backend`'s decision, taken from the
  `Nest.Sandbox.Mounts` value the caller passes: `"bwrap"` (the default) runs
  it under bubblewrap, `"docker"` inside the space's container, and `"none"`
  runs it bare on the host. Everything else here — the staged transcript, the
  deadline, the output collection, the failure diagnostics — is
  backend-independent.

  Commands run in an isolated environment when the backend provides one:
  - Network isolation (configurable via caps)
  - Read-only filesystem access (except the workspace and the scratch
    directory, when the mode grants them)
  - A fresh devtmpfs at /dev, so shell redirects like `> /dev/null` and
    `2>/dev/null` work as expected
  - Process namespace isolation
  - Proper cleanup on exit

  ## Sandbox Profile

  The profile is determined by the `caps` map and the `Nest.Sandbox.Mounts`
  value (see `Nest.Sandbox`). When `caps` is `nil` (legacy callers), the
  default profile is used:
  - Network: Disabled
  - Filesystem read: Entire host (read-only)
  - Filesystem write: The workspace directory (at its own path) and the
    scratch directory (bound at /tmp)
  - /dev: A fresh devtmpfs on a non-HPU host (overlays the read-only
    host /dev so device files like /dev/null are writable inside the
    sandbox). On an HPU host the host's `/dev` is re-bound with
    `--dev-bind` and the Habana log dir is bound read-write, so
    accelerator nodes are visible (see `Nest.Sandbox`).

  That profile is the *bwrap* backend's; `"none"` enforces none of it. See
  `Nest.Sandbox.Backend`.

  ## The command transcript

  The command text is written to a staged script and handed to bash as a
  *file*, never as `-c` text: that is what removes the escaping layer, so the
  command never has to survive as one quoted argv element. Where the script is
  staged, and what path bash is handed for it, is the backend's business
  (`Backend.stage_dir/1` / `stage_dir_sandbox/1`) — the staging directory is a
  bind source, so its host path and its sandbox spelling are different strings
  under bwrap and the same string on the bare command.
  """

  require Logger

  alias Nest.Sandbox.{Backend, Mounts, ShellJobs}
  alias Nest.Tools.Exec

  @default_timeout_ms 60_000
  @default_grace_ms 200

  # The largest value `receive ... after` accepts; anything above it raises
  # `ErlangError: :timeout_value` at the `receive`. `:timeout` itself has no
  # upper limit, so `collect_output/5` clamps only its *check-in interval* to
  # this and re-checks the real deadline — a bound longer than this is still
  # honoured in full.
  @max_after_ms 4_294_967_295

  @doc """
  The default wall-clock bound in milliseconds, used when `:timeout` is not
  given.

  Public because the model-visible `shell-cmd` tool description interpolates
  it (in seconds) rather than restating the number: one source of truth for
  the default.
  """
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  Executes a shell command in a sandboxed environment.

  ## Options

    * `:timeout` - Wall-clock limit in milliseconds for the whole command
      (default: #{@default_timeout_ms}), ignored with `:background`. There is
      no upper limit: a bound longer than `receive`'s `after` ceiling is
      honoured in full (only the check-in interval is clamped). The deadline
      is fixed when the command starts, so a command that keeps writing
      output cannot move it: it is killed at the deadline either way.
    * `:stdin` - Binary data to send to the command's stdin over a real pipe (no base64) (default: "")
    * `:background` - when `true`, start the command as a background job
      owned by `Nest.Sandbox.ShellJobs` and return a job handle instead of
      waiting. Requires a scratch directory (the job log lives under it, and
      the path reported to the agent is the sandbox's
      `/tmp/<agent-name>/shell-jobs/<id>.log`). Additional
      opts: `:agent_key` (`{space_id, agent_name}`), `:agent_pid`, and
      `:grace_ms` (how long to wait for an immediate exit before reporting
      the job as running).

  ## Returns

    * `{:ok, output}` - Command completed successfully
    * `{:error, output}` - Command failed or was terminated (a backend
      returning "Permission denied" surfaces as `{:error, "Exit code N: ..."}`)
    * `{:cancelled, reason}` - The space's environment changed under the
      command and the space edit called it off
      (`Nest.Agents.Agent.cancel_tools/2`). Not a failure: nothing went wrong,
      the call may be re-issued. Its own shape so a caller can tell it from an
      error — the tool path must not report a routine edit as one.

  Both success and failure return the command output, which should be
  displayed as a message in the chat UI.

  Pass `nil` for `caps` to use the default profile (no network, full
  host read-only, workspace + scratch writable). This is preserved for
  back-compat with callers that haven't been migrated.
  """
  @spec execute(String.t(), Mounts.t(), map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, String.t()} | {:cancelled, String.t()}
  def execute(command, mounts, caps \\ nil, opts \\ []) do
    with {:ok, mounts} <- validate_workspace(mounts),
         {:ok, spec, script, script_sandbox} <- build_command(command, mounts, caps) do
      dispatch(command, spec, script, script_sandbox, mounts, caps, opts)
    end
  end

  # Foreground vs background selection for a built command, kept out of
  # `execute/4` to hold its ABC size down.
  defp dispatch(command, spec, script, script_sandbox, mounts, caps, opts) do
    if Keyword.get(opts, :background, false) do
      run_background(command, script, script_sandbox, mounts, caps, opts)
    else
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
      stdin = normalize_stdin(Keyword.get(opts, :stdin))

      Logger.info(
        "Executing sandboxed script #{script} in #{Mounts.workspace(mounts) || "/"}: " <>
          truncate_log(command)
      )

      exec_staged(script, spec, timeout, stdin, command, mounts)
    end
  end

  @doc """
  Low-level sibling of `execute/4` for callers that need the raw exit code and
  the separated stdout/stderr streams instead of the decorated combined output.

  `Nest.Sandbox.read/3`, `stat/4`, and `glob/4` use this to run inside the
  sandbox: a
  read must see stdout exactly (an empty file is a valid read, so the
  `"[Command executed successfully with no output]"` placeholder `execute/4`
  emits is wrong here) and must inspect stderr to classify failures.

  Returns `{:ok, exit_code, stdout, stderr}` or `{:error, reason}`. There is no
  default for `caps`: `caps: nil` means the full default profile, so a caller
  that forgets to pass caps must not compile. `mounts` carries the two
  directories the sandbox binds, and is the only thing this module reads them
  out of.
  """
  @spec execute_raw(String.t(), Mounts.t(), map() | nil, keyword()) ::
          {:ok, non_neg_integer(), binary(), binary()} | {:error, String.t()}
  def execute_raw(command, mounts, caps, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    stdin = normalize_stdin(Keyword.get(opts, :stdin))

    with {:ok, mounts} <- validate_workspace(mounts),
         {:ok, spec, script, _script_sandbox} <- build_command(command, mounts, caps) do
      try do
        case run_with_erlexec_raw(spec, timeout, stdin) do
          # Nothing cancels a sandbox helper today (`cancel_tools/2` reaches tool
          # workers, and `stat`/`glob` are not long calls), but the shape has to
          # be total: an error string is what this function promises.
          {:cancelled, reason} -> {:error, reason}
          result -> result
        end
      after
        File.rm(script)
      end
    end
  end

  # Stage the command's transcript, then ask the backend for the command line
  # that runs it. The backend is resolved first so an unknown one is reported
  # before anything is written, and when the command cannot be built (e.g. a
  # workspace under the scratch bind) the staged script is removed and the
  # reason is returned rather than raised.
  #
  # Returns the spec, the staged file's host path, and the spelling the backend
  # hands the shell. The last one is only needed by a background job, whose
  # command line is built later (by `Nest.Sandbox.ShellJobs.Launcher`, which
  # knows the log path) — so it travels rather than being derived a second time.
  defp build_command(command, mounts, caps) do
    case Backend.resolve(mounts) do
      {:ok, _backend} ->
        Mounts.ensure_scratch!(mounts)
        {script, script_sandbox} = stage_script(command, mounts)

        case Backend.command(mounts, caps, script_sandbox) do
          {:ok, spec} ->
            {:ok, spec, script, script_sandbox}

          {:error, reason} ->
            File.rm(script)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Run the staged script and remove it afterwards: it is only a transcript of
  # the command, and all the caller keeps is the output, so it goes on every
  # path - success, failure, timeout or crash.
  defp exec_staged(script, spec, timeout, stdin, command, mounts) do
    case run_with_erlexec(spec, timeout, stdin) do
      {:ok, exit_code, output} ->
        handle_exit_result(command, exit_code, output, mounts)

      # The space's environment changed under the command and the space edit
      # called it off (`cancel_tools/2`). Not a failure to start and not a
      # failure to run: nothing is logged, because a deliberate cancellation is
      # not a defect to diagnose, and the caller gets the reason as a
      # cancellation so its own error diagnostics can stay off too.
      {:cancelled, reason} ->
        {:cancelled, reason}

      {:error, reason} ->
        handle_startup_failure(command, reason, mounts)
    end
  after
    File.rm(script)
  end

  # Start the command as a background job and either report an immediate
  # exit (within the grace window) as a normal result, or hand the caller a
  # job handle. `ShellJobs` removes the job's staged script when the job ends.
  #
  # The command line is the *launcher's* to build rather than this module's: a
  # job's output also has to reach its log file inside the environment, and for
  # the docker backend that means the command itself writes it — which needs the
  # log path, which the manager allocates. So the launcher is handed what the
  # backend needs (`caps` and the script's sandbox spelling) and asks for a job
  # spec (`Nest.Sandbox.Backend.job_spec/4`).
  defp run_background(command, script, script_sandbox, mounts, caps, opts) do
    if is_nil(Mounts.scratch(mounts)) do
      File.rm(script)
      {:error, "Background jobs require a tmp directory"}
    else
      grace = Keyword.get(opts, :grace_ms, @default_grace_ms)
      agent_key = Keyword.get(opts, :agent_key, {:unknown, :unknown})

      Logger.info(
        "Starting background shell job in #{Mounts.workspace(mounts) || "/"}: " <>
          truncate_log(command)
      )

      case ShellJobs.start_job(%{
             agent_key: agent_key,
             agent_pid: Keyword.get(opts, :agent_pid),
             command: command,
             caps: caps,
             script_sandbox: script_sandbox,
             script_path: script,
             mounts: mounts,
             max_jobs: background_cap(caps)
           }) do
        {:ok, job_id, log_path} ->
          await_background_start(job_id, log_path, grace, agent_key, command, mounts)

        {:error, reason} ->
          File.rm(script)
          {:error, reason}
      end
    end
  end

  defp await_background_start(job_id, log_path, grace, agent_key, command, mounts) do
    ShellJobs.subscribe(agent_key, job_id, self())

    receive do
      {:shell_job_exit, ^job_id, code} ->
        {:ok, output} = ShellJobs.output(agent_key, job_id)
        handle_exit_result(command, code, output, mounts)
    after
      grace ->
        ShellJobs.unsubscribe(agent_key, job_id, self())

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

  defp handle_exit_result(_command, 0, "", _mounts) do
    {:ok, "[Command executed successfully with no output]"}
  end

  defp handle_exit_result(_command, 0, output, _mounts) do
    {:ok, output}
  end

  defp handle_exit_result(command, exit_code, output, mounts) do
    log_sandbox_failure(command, exit_code, output, mounts)
    {:error, "Exit code #{exit_code}:\n#{output}"}
  end

  defp handle_startup_failure(command, reason, mounts) do
    log_erlexec_start_failure(command, reason, mounts)
    {:error, "Execution failed: #{reason}"}
  end

  # Permanent diagnostic. The sandbox command exiting non-zero is the rare
  # path; under heavy parallel load it can fire intermittently
  # for reasons we don't fully understand yet. We want the
  # server log to capture every occurrence with enough detail
  # to diagnose a flake from the log alone.
  #
  # Printing the directories is deliberate here, as it is on the two `info`
  # lines above: a flake is diagnosed by asking *which* directories the
  # failing invocation was given, and the agent's own `/tmp/<agent-name>/...`
  # spelling is not what the backend was handed. None of it reaches the agent —
  # this is the operator's log — so it is not the leak the sandbox-spelling
  # rule is about.
  #
  # The backend's display name leads the line, so a `"docker"` or `"none"`
  # space's failure is not reported as bwrap's. `Nest.Sandbox.Backend.Bwrap`
  # answers `"bwrap"`, which is why this reads exactly as it did when bwrap was
  # the only backend.
  defp log_sandbox_failure(command, exit_code, output, mounts) do
    Logger.error(
      "ShellCmd.execute: #{Backend.display_name(mounts)} exited non-zero " <>
        "(exit_code=#{exit_code}) for command=#{truncate_log(command)} " <>
        "workspace=#{Mounts.workspace(mounts) || "none"} " <>
        "scratch=#{Mounts.scratch(mounts) || "none"} " <>
        "output=#{inspect(output)}"
    )
  end

  defp log_erlexec_start_failure(command, reason, mounts) do
    Logger.error(
      "ShellCmd.execute: erlexec failed to start process " <>
        "(reason=#{inspect(reason)}) for command=#{truncate_log(command)} " <>
        "workspace=#{Mounts.workspace(mounts) || "none"} " <>
        "scratch=#{Mounts.scratch(mounts) || "none"}"
    )
  end

  # Stage the command's transcript for bash to read. The staging directory is
  # the backend's (`Backend.stage_dir/1`): inside the bound space scratch dir
  # (visible at `/tmp/.cmds`) when a scratch dir exists, else under the system
  # tmp dir (visible at the same path through the root read-only bind). Keeping
  # it out of the agent's own scratch dir means a glob over that dir never sees
  # it. The path handed to bash is the backend's sandbox spelling of the same
  # file — the two differ whenever the staging directory is reached through a
  # bind.
  defp stage_script(command, mounts) do
    dir = Backend.stage_dir(mounts)
    File.mkdir_p!(dir)
    path = Path.join(dir, script_name())
    File.write!(path, command)
    {path, Path.join(Backend.stage_dir_sandbox(mounts), Path.basename(path))}
  end

  defp script_name do
    "nest-cmd-#{System.unique_integer([:positive])}.sh"
  end

  defp normalize_stdin(nil), do: nil
  defp normalize_stdin(""), do: nil
  defp normalize_stdin(data), do: data

  # Private functions

  # No workspace: the backend binds no workspace and starts in the scratch
  # root (or `/`).
  defp validate_workspace(%Mounts{workspace: nil} = mounts), do: {:ok, mounts}

  defp validate_workspace(%Mounts{workspace: path} = mounts) do
    # The one place all three backends pass through for a command, so the
    # config-file refusal has to be here as well as in `Sandbox.build/4`:
    # `Docker.command/3` and `job_spec/4` build the inner bwrap from
    # `Binds.specs/2` and never reach `build/4`, and `None` builds no sandbox at
    # all.
    #
    # `Nest.ConfigFile.error/1` rather than `Sandbox.workspace_error/1`:
    # the latter canonicalises the path, and `FSPath.canonical/1` shells out to
    # `realpath` — a fork per command on the hottest path in the system. The
    # other two arms of `workspace_error/1` are covered here already (`File.dir?`)
    # or cannot occur (a workspace at or under `/tmp` is refused at creation).
    # `File.dir?` first, matching `Sandbox.workspace_error/1`'s order: a workspace
    # path that is a regular file should say the directory does not exist, not
    # name a config file inside something that is not a directory.
    if File.dir?(path) do
      case Nest.ConfigFile.error(path) do
        :ok ->
          {:ok, mounts}

        {:error, {:config_file_not_regular, _path, _type} = reason} ->
          {:error, Nest.ConfigFile.error_message(reason)}
      end
    else
      {:error, "Workspace directory does not exist: #{path}"}
    end
  end

  defp run_with_erlexec(spec, timeout, stdin) do
    case run_with_erlexec_streams(spec, timeout, stdin) do
      {:ok, exit_code, combined, _stdout, _stderr} -> {:ok, exit_code, combined}
      # A cancellation is passed through as its own shape: `exec_staged/6` must
      # not report it as a failure to *start* the process, which is what the
      # `{:error, _}` clause means (nothing was started, and nothing ran).
      {:cancelled, reason} -> {:cancelled, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_with_erlexec_raw(spec, timeout, stdin) do
    case run_with_erlexec_streams(spec, timeout, stdin) do
      {:ok, exit_code, _combined, stdout, stderr} -> {:ok, exit_code, stdout, stderr}
      {:cancelled, reason} -> {:cancelled, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # The erlexec option list for a built command. `{:cd, dir}` is how a backend
  # that has no chdir of its own (the bare command) starts the command in the
  # workspace; bwrap and docker both carry their own working directory, so they
  # answer `nil` and this stays out of the list.
  defp exec_options(spec, stdin_opt) do
    base = [:stdout, :stderr, :monitor, stdin_opt, {:kill_timeout, 5000}]

    case spec.cd do
      nil -> base
      dir -> [{:cd, dir} | base]
    end
  end

  defp run_with_erlexec_streams(spec, timeout, stdin) do
    stdin_opt = if stdin, do: :stdin, else: {:stdin, :null}

    # `:erlexec` is kept out of the boot-time `applications` list outside
    # prod (see `mix.exs`); start it here so the first shell command pays
    # its one-off 350ms instead of every boot.
    Exec.ensure_started()

    # The deadline is computed once, when the command starts, and never
    # moves: `collect_output/5` re-derives the time left on every iteration,
    # so a command that writes at least once per `timeout` is still killed
    # at the deadline. (An idle timer re-armed by every chunk would let it
    # run forever.)
    deadline = System.monotonic_time(:millisecond) + timeout

    # A cancellation that arrived while this worker was *not* running a command —
    # parked at the space's gate, or between two calls of a batch — is still in
    # the mailbox, and `collect_output/5` matches `{:cancel_tool, _}` before any
    # output. Left there, it would stop a command that started in the *new*
    # environment and report a cancellation nobody asked for: a non-idempotent
    # command cut in half is the half-changed state the latch exists to prevent.
    # The `:DOWN` clause is scoped by `^erl_pid` for the same reason; this message
    # cannot be, because the command it would have cancelled no longer exists.
    flush_cancel_tool()

    case :exec.run(
           to_charlist(spec.command),
           exec_options(spec, stdin_opt)
         ) do
      # erlexec's `:monitor` option emulates a monitor with a per-run
      # lightweight process (`deps/erlexec/src/exec.erl`, `ospid_init/7`),
      # returned here as `erl_pid`; its `:DOWN` names that pid, not `os_pid`.
      # Only this call's own `:DOWN` may end this call: a previous call's
      # `:DOWN` is left undrained by `handle_timeout/3`/`handle_stop_chat/2`
      # and would otherwise be consumed as this call's result.
      {:ok, erl_pid, os_pid} ->
        send_stdin(os_pid, stdin)

        # Buffers are IO lists (prepend in O(1)); the terminal handler
        # flattens each stream to a binary.
        collect_output(erl_pid, os_pid, deadline, timeout, %{
          stdout: [],
          stderr: [],
          exit_code: nil
        })

      {:error, reason} ->
        {:error, "Failed to start process: #{inspect(reason)}"}
    end
  end

  # Drop `{:cancel_tool, _}` messages a cancellation left in this worker's mailbox
  # while it had no command to stop. Called once, immediately before a command
  # starts, so the window it leaves is only "cancelled between the flush and
  # `:exec.run/2" — which is the intended behaviour anyway: the latch is up, and a
  # command about to start is exactly what a cancellation should catch.
  defp flush_cancel_tool do
    receive do
      {:cancel_tool, _reason} -> flush_cancel_tool()
    after
      0 -> :ok
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

  # `timeout` is the command's total bound; `deadline` is when it expires
  # (monotonic ms). Each iteration re-derives the time left from the
  # deadline, so stdout/stderr arriving in the meantime cannot push the
  # expiry back. `timeout` rides along only to word the timeout marker.
  # `erl_pid` is erlexec's per-run monitor process: only its `:DOWN` ends
  # this call, so an earlier command's stale `:DOWN` — left in the tool
  # worker's mailbox by a timeout or a Stop — is skipped instead of being
  # returned as this command's result.
  defp collect_output(erl_pid, os_pid, deadline, timeout, acc) do
    receive do
      {:stdout, ^os_pid, data} ->
        check_deadline(erl_pid, os_pid, deadline, timeout, append_stdout(acc, data))

      {:stderr, ^os_pid, data} ->
        check_deadline(erl_pid, os_pid, deadline, timeout, append_stderr(acc, data))

      {:stop_chat, _from} ->
        handle_stop_chat(os_pid, acc)

      {:cancel_tool, reason} ->
        handle_cancel_tool(os_pid, reason)

      {:DOWN, _ref, :process, ^erl_pid, reason} ->
        handle_down(acc, reason)
    after
      remaining_ms(deadline) ->
        check_deadline(erl_pid, os_pid, deadline, timeout, acc)
    end
  end

  # The deadline is consulted after *every* chunk, not only when the mailbox
  # goes quiet. A command that floods stdout never leaves the mailbox empty,
  # so an `after`-only check would never run and the bound would not be the
  # wall-clock bound it is documented to be. `{:stop_chat, _}` and this run's
  # `:DOWN` keep their existing precedence: they are matched by the `receive`
  # above, and this check only runs after a chunk that already matched.
  defp check_deadline(erl_pid, os_pid, deadline, timeout, acc) do
    if System.monotonic_time(:millisecond) >= deadline do
      handle_timeout(os_pid, timeout, acc)
    else
      collect_output(erl_pid, os_pid, deadline, timeout, acc)
    end
  end

  # Time left before the deadline, floored at 0 (an expired deadline must fire
  # the `after` immediately rather than raise) and capped at `@max_after_ms`
  # (the largest `after` accepts; see the attribute). The floor is also what
  # makes a directly-passed negative `:timeout` an immediate timeout, whose
  # marker then reads `[Command timed out after -5ms]` — unreachable through
  # the `shell-cmd` tool, which rejects non-positive values.
  defp remaining_ms(deadline) do
    (deadline - System.monotonic_time(:millisecond))
    |> max(0)
    |> min(@max_after_ms)
  end

  defp append_stdout(acc, data),
    do: %{acc | stdout: [to_string(data) | acc.stdout]}

  defp append_stderr(acc, data),
    do: %{acc | stderr: [to_string(data) | acc.stderr]}

  # The user clicked Stop. `Agent.stop_chat/2` forwards
  # `{:stop_chat, _}` to the tool worker before
  # `Process.exit(worker, :kill)` so we can clean up the sandbox
  # OS process explicitly. Without this, the `:erlexec` port
  # close + `:kill_timeout, 5000` cleanup is fragile (bwrap's
  # PID namespace isolation can leave the inner command
  # running).
  defp handle_stop_chat(os_pid, acc) do
    :exec.stop(os_pid)
    # The marker goes in *stderr* so both `execute/4` (which renders stderr via
    # `combine_output/1`) and `execute_raw/3,4` (which classifies stderr) see
    # it; appending it to the combined output dropped it for raw callers.
    acc = append_stderr(acc, "[Command cancelled]")
    # 130 = 128 + SIGINT(2), the conventional shell cancellation
    # exit code (Ctrl-C).
    {:ok, 130, combine_output(acc), stdout_bin(acc), stderr_bin(acc)}
  end

  # The space's environment changed under this command, so the space edit
  # cancelled it (`Nest.Agents.Agent.cancel_tools/2`). This is deliberately *not*
  # the Stop path: a Stop is the human ending the turn, and its result is the
  # command's own cancelled exit code. Here the command did not run to
  # completion, so this is not a result at all — the agent gets a tool error and
  # can re-issue the call against the space's new values.
  #
  # `{:cancelled, _}` rather than `{:error, _}` so the caller can tell a command
  # that was called off from one that never started: only the latter is a
  # failure worth a line in the operator log.
  #
  # This clause is the *only* one in the build, and that is the rule rather than
  # an accident: cancellation is a message to a worker that owns an OS process,
  # and a command is the one tool shape that does. A short tool waits at the gate
  # instead (`Nest.Agents.SpaceGate`'s moduledoc states it), so it needs no clause
  # and burns no retry.
  defp handle_cancel_tool(os_pid, reason) do
    :exec.stop(os_pid)
    {:cancelled, reason}
  end

  defp handle_down(acc, reason) do
    {:ok, exit_code(reason), combine_output(acc), stdout_bin(acc), stderr_bin(acc)}
  end

  @doc """
  Decode the `:DOWN` reason erlexec reports for a finished command into a shell
  exit code.

  erlexec reports the wait status the OS recorded: `:normal` for status 0 and
  `{:exit_status, raw}` otherwise (a signal death included, so a killed command
  is not a clean exit). `:exec.status/1` decodes the raw value; a signal death
  becomes `128 + signo`, the conventional shell spelling. Shared with
  `Nest.Sandbox.ShellJobs`, which decodes the same reason for background jobs.
  """
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
    # `:exec.stop/1` is asynchronous: this returns before erlexec's `:DOWN`
    # for the killed process arrives, so that `:DOWN` is left in the caller's
    # mailbox. Harmless: the next `collect_output/5` matches only the erlexec
    # pid of its own command, so it skips the stale one instead of reporting
    # it as its own result.
    # Stderr, like `handle_stop_chat/2`, so `execute_raw/3,4` sees the marker.
    acc = append_stderr(acc, "[Command timed out after #{timeout}ms]")
    {:ok, 1, combine_output(acc), stdout_bin(acc), stderr_bin(acc)}
  end

  defp combine_output(acc) do
    output = stdout_bin(acc)

    if acc.stderr == [] do
      output
    else
      output <> "\n[stderr]\n" <> stderr_bin(acc)
    end
  end

  defp stdout_bin(acc), do: acc.stdout |> Enum.reverse() |> IO.iodata_to_binary()

  defp stderr_bin(acc), do: acc.stderr |> Enum.reverse() |> IO.iodata_to_binary()

  defp truncate_log(command) do
    if String.length(command) > 100 do
      String.slice(command, 0, 100) <> "..."
    else
      command
    end
  end
end
