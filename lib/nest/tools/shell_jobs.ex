defmodule Nest.Tools.ShellJobs do
  @moduledoc """
  Tools for managing background shell jobs started by
  `shell-cmd background: true`.

  The job manager itself is `Nest.Sandbox.ShellJobs`. These tools read
  the per-call context (`space_id` + `agent_name`) to scope every
  operation to the calling agent, except `shell-list` and `shell-kill`: those
  two may cross to another agent's jobs, but only within the caller's own
  space, so a job a sibling left holding locks can be found and stopped.
  `shell-wait` stays owner-scoped.
  """

  alias Nest.Agents.Agent.Watch
  alias Nest.LLM.Tool
  alias Nest.Sandbox.ShellJobs

  @default_wait_ms 300_000
  @kill_wait_ms 2_000

  @doc "The `shell-list` tool: enumerate background jobs, per agent or per space."
  @spec list_function() :: Tool.t()
  def list_function do
    %Tool{
      name: "shell-list",
      description:
        "List background shell jobs (started with `shell-cmd`'s " <>
          "`background: true`), with each job's status, exit code, and log " <>
          "path. `scope` is \"agent\" (the default: your own jobs) or " <>
          "\"space\" (every job in this space, including other agents' jobs, " <>
          "each labelled with the agent that owns it). Use `shell-wait` to " <>
          "watch for one of your own to finish and `shell-kill` to stop one — " <>
          "your own, or another agent's in this space.",
      parameters_schema: %{
        "type" => "object",
        "properties" => %{
          "scope" => %{
            "type" => "string",
            "enum" => ["agent", "space"],
            "description" =>
              "Which jobs to list: \"agent\" (default) for your own, " <>
                "\"space\" for every agent's jobs in this space."
          },
          "max_result_tokens" => Nest.Tools.max_result_tokens_schema()
        },
        "required" => []
      },
      function: fn args, context -> list(args, context) end
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
      description:
        "Stop a running background shell job by id. The id may be one of your " <>
          "own jobs or another agent's job in your space; when it is another " <>
          "agent's, the result says whose it was.",
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

  # `agent` is the default: the space listing shows jobs the caller does not
  # own, so it has to be asked for.
  defp list(args, context) do
    case Map.get(args, "scope", "agent") do
      "agent" -> {:ok, render(ShellJobs.list(agent_key(context)))}
      "space" -> {:ok, render_space(ShellJobs.list_space(space_id(context)))}
      other -> {:error, "Unknown scope #{inspect(other)}: use \"agent\" or \"space\"."}
    end
  end

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

  # The caller's own jobs are tried first — the common case — then its space.
  # `kill_space/2` answers with the owner's key, which names whose job it was
  # and is what the wait below needs: `subscribe/3` is owner-scoped.
  defp kill(%{"id" => id}, context) do
    key = agent_key(context)

    case ShellJobs.kill(key, id) do
      :ok -> await_killed(key, id, nil)
      {:error, :not_found} -> kill_in_space(id, context)
    end
  end

  defp kill_in_space(id, context) do
    case ShellJobs.kill_space(space_id(context), id) do
      {:ok, owner} -> await_killed(owner, id, elem(owner, 1))
      {:error, :not_found} -> {:error, "No such background job: #{id}"}
    end
  end

  defp await_killed(key, id, owner) do
    ShellJobs.subscribe(key, id, self())

    receive do
      {:shell_job_exit, ^id, code} -> {:ok, killed_text(id, owner, code)}
    after
      @kill_wait_ms ->
        # The exit may have been handled between the timeout and this call, in
        # which case its message arrived after we stopped listening. The reply
        # is the state at the removal, so the exit code is not lost — and for
        # the owner's own kill there is no notice to report it instead.
        case ShellJobs.unsubscribe(key, id, self()) do
          {:exited, code} -> {:ok, killed_text(id, owner, code)}
          _running_trimmed_or_gone -> {:ok, killed_text(id, owner, nil)}
        end
    end
  end

  # A nil owner is the caller's own job, whose wording is unchanged.
  defp killed_text(id, nil, nil), do: "Killed background job #{id}."
  defp killed_text(id, nil, code), do: "Killed background job #{id} (exit code #{code})."

  defp killed_text(id, owner, nil),
    do: "Killed background job #{id}, owned by #{owner}."

  defp killed_text(id, owner, code),
    do: "Killed background job #{id}, owned by #{owner} (exit code #{code})."

  defp render([]), do: "No background jobs."

  defp render(jobs), do: Enum.map_join(jobs, "\n", &render_job/1)

  defp render_job(job) do
    "- #{job.id}: #{job.status}" <>
      status_suffix(job) <> " — #{job.command} (log: #{job.log_path})"
  end

  defp render_space([]), do: "No background jobs in this space."

  defp render_space(jobs), do: Enum.map_join(jobs, "\n", &render_space_job/1)

  # The owner column is the point of the space listing: an agent looks because
  # the job it needs is not its own. A job whose key names no agent says so
  # rather than dropping the column.
  defp render_space_job(job) do
    "- #{job.id} (owner: #{job.agent || "unknown"}): #{job.status}" <>
      status_suffix(job) <> " — #{job.command} (log: #{job.log_path})"
  end

  defp status_suffix(%{status: :exited, exit_code: code, killed: true}),
    do: " (killed, exit #{code})"

  defp status_suffix(%{status: :exited, exit_code: code}), do: " (exit #{code})"
  defp status_suffix(_job), do: ""

  defp agent_key(context) do
    Nest.Tools.agent_key(context)
  end

  # The space half of the caller's key: shared by every agent in the space, so
  # a space listing or kill cannot reach another space's jobs.
  defp space_id(context), do: elem(agent_key(context), 0)

  defp max_timeout(n) when is_integer(n) and n > 0, do: n
  defp max_timeout(_), do: @default_wait_ms
end
