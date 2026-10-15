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
  @spec list_function() :: Tool.t()
  def list_function do
    %Tool{
      name: "shell-list",
      description:
        "List your background shell jobs (started with `shell-cmd`'s " <>
          "`background: true`), with each job's status, exit code, and log " <>
          "path. Use `shell-wait` to watch for one to finish and `shell-kill` " <>
          "to stop one.",
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
          "exit code. A job that has already finished reports its output now, " <>
          "in this result. A job that is still running ends your turn: the job's " <>
          "result is delivered as a message when it exits, and nothing you do " <>
          "waits for it. The `timeout` bounds the watch, not the call: if it " <>
          "expires you are woken by a message saying so, and the job keeps " <>
          "running.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "description" => "The background job id."},
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Maximum milliseconds to watch for the job to exit. Defaults to " <>
                "#{@default_wait_ms}. Reaching it is a normal result, delivered as " <>
                "a message, not an error."
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

  # `shell-wait` never waits on the caller's side (issue #54). A job that has
  # already finished reports its output inline, like any tool whose answer is
  # already known; a running job registers a watch — reported as `{:waiting, …}`,
  # which the machine reads and ends the caller's turn for — and the job's
  # result arrives as a notice when it exits.
  #
  # The already-exited check is not an optimisation. `ShellJobs.subscribe/3`
  # sends `{:shell_job_exit, …}` immediately for an exited job, so a watch on
  # one fires while the caller's tool batch is still settling: the delivery can
  # land in the caller's inbox before the batch's own results do, and the
  # machine then backgrounds the batch instead of ending the turn. Reading the
  # status first makes both paths deterministic.
  defp wait(%{"id" => id} = args, context) do
    timeout = max_timeout(args["timeout"])
    key = agent_key(context)

    case ShellJobs.status(key, id) do
      {:error, :not_found} -> {:error, "No such background job: #{id}"}
      {:ok, {:exited, code}} -> {:ok, ShellJobs.result_text(id, code, output(key, id))}
      {:ok, :running} -> Watch.register_shell_call(context, id, timeout)
    end
  end

  # The job's captured output. A log the manager dropped with its agent reads
  # as empty; the exit code is what carries the verdict either way.
  defp output(key, id) do
    case ShellJobs.output(key, id) do
      {:ok, output} -> output
      {:error, _} -> ""
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
