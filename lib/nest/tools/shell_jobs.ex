defmodule Nest.Tools.ShellJobs do
  @moduledoc """
  Tools for managing background shell jobs started by
  `shell-cmd background: true`.

  The job manager itself is `Nest.Sandbox.ShellJobs`. These tools read
  the per-call context (`space_id` + `agent_name`) to scope every
  operation to the calling agent.
  """

  alias Nest.Agents.Agent.Watch
  alias Nest.LLM.Tool
  alias Nest.Sandbox.ShellJobs

  @default_wait_ms 300_000
  @kill_wait_ms 2_000

  @doc "The `shell-list` tool: enumerate this agent's background jobs."
  @spec list_function(String.t() | nil) :: Tool.t()
  def list_function(tmp_path \\ nil) do
    %Tool{
      name: "shell-list",
      description:
        "List your background shell jobs (started with `shell-cmd`'s " <>
          "`background: true`), with each job's status, exit code, and log " <>
          "path. Use `shell-wait` to block for one to finish and `shell-kill` " <>
          "to stop one." <>
          Nest.Tools.scratch_note(tmp_path),
      parameters_schema: %{
        "type" => "object",
        "properties" => %{"max_result_tokens" => Nest.Tools.max_result_tokens_schema()},
        "required" => []
      },
      function: fn _args, context ->
        {:ok, render(ShellJobs.list(agent_key(context)))}
      end
    }
  end

  @doc "The `shell-wait` tool: watch for a background job to exit."
  @spec wait_function() :: Tool.t()
  def wait_function do
    %Tool{
      name: "shell-wait",
      description:
        "Wait for a background shell job to finish and report its output and " <>
          "exit code. By default this returns immediately and leaves you idle so " <>
          "a human can message you: the job's result is delivered as a message " <>
          "when it exits. Pass `block: true` to block this turn instead (bounded " <>
          "by `timeout` ms, default #{@default_wait_ms}); if it times out the job " <>
          "keeps running.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "The background job id."},
          "block" => %{
            "type" => "boolean",
            "description" =>
              "When true, block this turn until the job exits instead of " <>
                "returning immediately. Defaults to false (non-blocking: you go " <>
                "idle and the result arrives as a message)."
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Maximum milliseconds to wait. Defaults to #{@default_wait_ms}."
          },
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => ["id"]
      },
      function: fn args, context -> wait(args, context) end
    }
  end

  @doc "The `shell-kill` tool: stop a background job."
  @spec kill_function() :: Tool.t()
  def kill_function do
    %Tool{
      name: "shell-kill",
      description: "Stop a running background shell job by id.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "The background job id."}
        },
        "required" => ["id"]
      },
      function: fn args, context -> kill(args, context) end
    }
  end

  # ---- Implementations ----

  # Non-blocking by default (issue #54): validate the job exists, then register
  # a watch and return. The result is delivered as a notice when the job exits.
  # `block: true` keeps the old in-worker wait.
  defp wait(%{"id" => id} = args, context) do
    timeout = max_timeout(args["timeout"])

    if args["block"] == true do
      blocking_wait(id, context, timeout)
    else
      async_wait(id, context, timeout)
    end
  end

  defp async_wait(id, context, timeout) do
    case ShellJobs.status(agent_key(context), id) do
      {:error, :not_found} ->
        {:error, "No such background job: #{id}"}

      {:ok, _status} ->
        Watch.register_shell_call(context, id, timeout)
    end
  end

  defp blocking_wait(id, context, timeout) do
    key = agent_key(context)

    case ShellJobs.subscribe(key, id, self()) do
      {:error, :not_found} ->
        {:error, "No such background job: #{id}"}

      :ok ->
        receive do
          {:shell_job_exit, ^id, code} ->
            {:ok, output} = ShellJobs.output(key, id)
            wait_result(id, code, output)

          {:stop_chat, _from} ->
            ShellJobs.unsubscribe(key, id, self())
            {:ok, "Stopped waiting; background job #{id} is still running."}
        after
          timeout ->
            ShellJobs.unsubscribe(key, id, self())
            {:ok, "Timed out waiting for background job #{id}; it is still running."}
        end
    end
  end

  defp kill(%{"id" => id}, context) do
    key = agent_key(context)

    case ShellJobs.kill(key, id) do
      {:error, :not_found} ->
        {:error, "No such background job: #{id}"}

      :ok ->
        await_killed(key, id)
    end
  end

  defp await_killed(key, id) do
    ShellJobs.subscribe(key, id, self())

    receive do
      {:shell_job_exit, ^id, code} -> {:ok, "Killed background job #{id} (exit code #{code})."}
    after
      @kill_wait_ms ->
        ShellJobs.unsubscribe(key, id, self())
        {:ok, "Killed background job #{id}."}
    end
  end

  defp wait_result(id, code, output), do: {:ok, ShellJobs.result_text(id, code, output)}

  defp render([]), do: "No background jobs."

  defp render(jobs), do: Enum.map_join(jobs, "\n", &render_job/1)

  defp render_job(job) do
    "- #{job.id}: #{job.status}" <>
      status_suffix(job) <> " — #{job.command} (log: #{job.log_path})"
  end

  defp status_suffix(%{status: :exited, exit_code: code, killed: true}),
    do: " (killed, exit #{code})"

  defp status_suffix(%{status: :exited, exit_code: code}), do: " (exit #{code})"
  defp status_suffix(_job), do: ""

  defp agent_key(context) do
    Nest.Tools.agent_key(context)
  end

  defp max_timeout(n) when is_integer(n) and n > 0, do: n
  defp max_timeout(_), do: @default_wait_ms
end
