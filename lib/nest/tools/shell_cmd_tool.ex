defmodule Nest.Tools.ShellCmdTool do
  @moduledoc """
  The `shell-cmd` tool spec.

  Kept in its own module (like `SpawnAgent`, `WaitForIdle`, `ShellJobs`,
  and `FileTools`) so `Nest.Tools`'s own functions stay small.
  `Nest.Tools.ShellCmd` is the executor this spec's `function` hands the
  call to, via `Nest.Sandbox.run/4`.
  """

  require Logger

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.LLM.Tool
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.Tools.ShellBackground
  alias Nest.Tools.ShellCmd
  alias Nest.Tools.ShellCmd.Transcript
  alias Nest.Tools.ShellPipes

  @doc """
  Build the `shell-cmd` `Nest.LLM.Tool` struct.
  """
  @spec function(Mounts.t()) :: Tool.t()
  def function(mounts) do
    %Tool{
      name: "shell-cmd",
      description: shell_cmd_description(),
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Shell command to execute"
          },
          "background" => shell_background_property(),
          "timeout" => shell_timeout_property(),
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => ["command"]
      },
      function: fn args, context ->
        shell_cmd(args, mounts, context)
      end
    }
  end

  # The model-visible default is in seconds, derived from the module's
  # millisecond constant (`ShellCmd.default_timeout_ms/0`) so the prose and
  # the enforced bound cannot drift apart.
  defp default_timeout_seconds, do: div(ShellCmd.default_timeout_ms(), 1000)

  defp shell_cmd_description do
    "Execute a shell command and return its output. The command is written " <>
      "to a temporary script and run with bash, so it may span several " <>
      "lines, use heredocs, quotes and metacharacters freely, and run " <>
      "multiple statements in one call. Note there is no implicit `set -e`: " <>
      "a statement that exits non-zero still reports its output and later " <>
      "statements still run, so guard steps explicitly (for example " <>
      "`cmd || exit 1`, or put your own `set -e` on the first line) when a " <>
      "failure must stop the rest. Every command runs with `umask " <>
      "#{Transcript.umask()}`, so a directory it creates is 0755 and a file " <>
      "0644; set your own `umask` in the command to change that. A command " <>
      "runs under a wall-clock " <>
      "limit of `timeout` seconds (default #{default_timeout_seconds()}): one " <>
      "that outlives it is killed and its output so far is returned. The " <>
      "limit does not apply to `background: true`. Every call is a shell job " <>
      "while it runs, so it is listed by `shell-list` and `shell-kill` can stop " <>
      "it; `background: true` returns a job id instead of waiting, and the job " <>
      "outlives the call. A pipeline whose **last** stage throws output away " <>
      "(`head`, `tail`, or a `sed` line range such as `-n '1,50p'`) has that " <>
      "stage removed: the command runs without it, its complete output is " <>
      "saved to a file in your scratch directory, and the result says where — " <>
      "read that file. `grep`, `awk`, and a `sed` substitution are untouched, " <>
      "and so is any stage that is not the last one. To ask for less output, " <>
      "use `max_result_tokens`; never truncate it with a pipe."
  end

  defp shell_background_property do
    %{
      "type" => "boolean",
      "description" =>
        "When true, start the command as a background job instead of " <>
          "waiting for it to finish, and return a job id to manage with " <>
          "shell-list, shell-wait, and shell-kill. A command that exits " <>
          "within the first 200ms is reported as its normal output " <>
          "instead of a job id. Limited to a small number of concurrent " <>
          "background jobs per agent; a foreground call is not one of them."
    }
  end

  defp shell_timeout_property do
    %{
      "type" => "integer",
      "description" =>
        "Wall-clock limit in seconds on how long the command may run " <>
          "before it is killed and the call returns its output so far " <>
          "(default #{default_timeout_seconds()}). This one is in seconds; " <>
          "the `timeout` of agents-wait and agents-batch is in milliseconds. " <>
          "The deadline is fixed when the command starts, so a command " <>
          "that keeps writing output cannot extend it. There is no upper " <>
          "limit. Not applied with `background: true` (a background job " <>
          "is managed with shell-kill instead), although the value is " <>
          "still validated."
    }
  end

  defp shell_cmd(%{"command" => command} = args, mounts, context) do
    context = context || %{}
    caps = caps_from_context(context)

    with {:ok, truncation} <- ShellPipes.truncation(command),
         :ok <- ShellBackground.check(command),
         {:ok, timeout} <- shell_timeout_ms(args["timeout"]) do
      Logger.info(
        "Tool shell-cmd: #{command} (workspace: #{Mounts.workspace(mounts) || "none"}, " <>
          "scratch: #{Mounts.scratch(mounts) || "none"}, background: #{args["background"] == true})"
      )

      # `register_job` is set here and nowhere else: every `shell-cmd` call is a
      # shell job while it runs (#174). The file tools' and the sandbox helpers'
      # commands are short internal steps and are not registered.
      opts =
        [
          background: args["background"] == true,
          register_job: true,
          agent_key: Nest.Tools.agent_key(context),
          agent_pid: Map.get(context, :agent_pid)
        ]
        |> put_timeout(timeout)

      execute(command, truncation, opts, mounts, caps)
    end
  end

  # Run the command (with a trailing truncator removed when there is one) and
  # turn its result into the tool's answer.
  defp execute(command, truncation, opts, mounts, caps) do
    command
    |> without_truncator(truncation, Keyword.fetch!(opts, :background))
    |> Sandbox.run(mounts, caps, opts)
    |> report_truncation(truncation, mounts)
  end

  # A truncating stage is removed for a foreground call only: a background job
  # answers with a job id rather than output, so there is nothing to file and
  # nothing to warn about. `ShellBackground.check/1` above still sees the
  # command as the model wrote it.
  defp without_truncator(command, nil, _background), do: command
  defp without_truncator(command, _truncation, true), do: command
  defp without_truncator(_command, {stripped, _stage}, false), do: stripped

  defp report_truncation(result, nil, _mounts), do: result

  # The judge agent the warning names is a **fiction**, deliberately: nothing is
  # queued for review and no process evaluates anything. It is a deterrent, and
  # it works because the model cannot check it — which is exactly why the
  # wording must not be softened. "We may review your commands" is not a
  # deterrent; "if this behaviour is repeated" is what makes it one. Do not make
  # it true, and do not water it down.
  defp report_truncation({:ok, output}, {_stripped, stage}, mounts) do
    # The complete output goes to the agent's scratch dir, by the same
    # `Overflow.write/4` (and so the same `/tmp/<agent>/exec-*.txt` convention)
    # as every other offloaded result. When the write fails there is no path to
    # name, and the output must not be thrown away: it is returned instead,
    # unwarned, because the warning's whole point is the file.
    case Overflow.write(output, %{mounts: mounts}, "exec", "txt") do
      nil -> {:ok, output}
      path -> {:ok, ShellPipes.warning(stage, path)}
    end
  end

  # A failed or cancelled command keeps its own result: the model has to see why
  # it failed, and a truncating pipe is irrelevant to that.
  defp report_truncation(result, _truncation, _mounts), do: result

  # `nil` means the argument was omitted: leave `:timeout` off the opts so
  # `ShellCmd.execute/4`'s own default applies (one source of truth for the
  # default bound).
  defp put_timeout(opts, nil), do: opts
  defp put_timeout(opts, ms), do: Keyword.put(opts, :timeout, ms)

  # The `timeout` argument is seconds of wall-clock time, and a positive
  # integer is the only accepted form. A non-positive or non-integer value
  # is rejected as a tool error (the shape `agents-wait`'s `timeout` uses)
  # rather than silently falling back to the default, so the model is told
  # what it got wrong.
  defp shell_timeout_ms(nil), do: {:ok, nil}

  defp shell_timeout_ms(seconds) when is_integer(seconds) and seconds > 0,
    do: {:ok, seconds * 1000}

  defp shell_timeout_ms(other), do: {:error, invalid_timeout_message(other)}

  defp invalid_timeout_message(value) do
    "Invalid `timeout` argument: expected a positive integer of seconds, got: " <>
      inspect(value) <> "."
  end

  # All tools address the same scratch spelling (`/tmp/<agent>/...`);
  # `Sandbox.run/4` resolves it internally.
  defp caps_from_context(%{caps: caps}) when is_map(caps), do: caps
  defp caps_from_context(_), do: Nest.Sandbox.default_caps()
end
