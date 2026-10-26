defmodule Nest.Tools.ShellCmdTool do
  @moduledoc """
  The `shell-cmd` tool spec.

  Kept in its own module (like `SpawnAgent`, `WaitForIdle`, `ShellJobs`,
  and `FileTools`) so `Nest.Tools`'s own functions stay small.
  `Nest.Tools.ShellCmd` is the executor this spec's `function` hands the
  call to, via `Nest.Sandbox.run/4`.
  """

  require Logger

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
      "limit does not apply to `background: true`."
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
          "jobs per agent."
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

    with :ok <- ShellPipes.check(command),
         :ok <- ShellBackground.check(command),
         {:ok, timeout} <- shell_timeout_ms(args["timeout"]) do
      Logger.info(
        "Tool shell-cmd: #{command} (workspace: #{Mounts.workspace(mounts) || "none"}, " <>
          "scratch: #{Mounts.scratch(mounts) || "none"}, background: #{args["background"] == true})"
      )

      opts =
        [
          background: args["background"] == true,
          agent_key: Nest.Tools.agent_key(context),
          agent_pid: Map.get(context, :agent_pid)
        ]
        |> put_timeout(timeout)

      Sandbox.run(command, mounts, caps, opts)
    end
  end

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
