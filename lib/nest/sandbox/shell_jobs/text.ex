defmodule Nest.Sandbox.ShellJobs.Text do
  @moduledoc """
  The sentences `Nest.Sandbox.ShellJobs` says.

  Split out of the manager for its file cap, like `Waiters` and `ExitNotice`, and
  because a job's exit is reported from three places — `shell-wait`'s inline
  answer, the watcher's message, and the owner's notice (`ShellJobNotice`) — so
  the wording has to have one home or the three drift.
  """

  alias Nest.Sandbox.ShellJobs

  @doc """
  The result text for a finished job, shared by `shell-wait`'s inline answer
  (issue #54: a job that had already exited), the watcher that delivers the exit
  as a message, and the owner's notice, so the wordings cannot drift.
  """
  @spec result_text(ShellJobs.job_id(), integer(), binary()) :: String.t()
  def result_text(id, 0, ""), do: "Background job #{id} exited 0 with no output."

  def result_text(id, code, output),
    do: "Background job #{id} exited with code #{code}:\n#{output}"

  @doc """
  The result text for a job whose agent stopped, delivered by the watcher's
  `{:shell_job_gone, …}` arm and by the `:gone` answer to `unsubscribe/3`.

  Deliberately not `result_text/3`'s shape: the job did not exit, it was
  dropped with its agent (`drop_agent/3`), so there is no exit code to report
  and the log may already be gone with the agent's tmp directory. Wording it as
  an exit would be a lie about what happened.
  """
  @spec gone_text(ShellJobs.job_id()) :: String.t()
  def gone_text(id), do: "Background job #{id} is gone: the agent that owned it stopped."

  @doc """
  The text for a job that exited but whose record retention has since evicted
  (`Nest.Sandbox.ShellJobs.trim/2` keeps the newest `@max_finished_per_agent`).

  Deliberately not `gone_text/1`: the agent is fine, so saying it stopped would
  be a lie. The job did finish; only its exit code went with the record.
  """
  @spec trimmed_text(ShellJobs.job_id()) :: String.t()
  def trimmed_text(id),
    do: "Background job #{id} finished; its result is no longer retained."

  @doc "Why a job could not start: the project disabled background jobs."
  @spec background_disabled() :: String.t()
  def background_disabled do
    "Background shell jobs are disabled for this project (set `[shell] background` above 0 in .nest)."
  end

  @doc "Why a job could not start: the agent is at its concurrent-job ceiling."
  @spec cap_reached(non_neg_integer()) :: String.t()
  def cap_reached(max) do
    "Background shell job limit reached (#{max} per agent). Use shell-list and shell-kill, " <>
      "or raise `[shell] background` in .nest."
  end
end
