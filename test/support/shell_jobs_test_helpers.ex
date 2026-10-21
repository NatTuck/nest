defmodule Nest.Sandbox.ShellJobsTestHelpers do
  @moduledoc """
  Starting a background job the way a tool does, for the manager's own tests.

  `ShellCmd` stages a script and hands the manager its mounts; a test that wants
  a job without going through the tool does the same here. Shared by
  `Nest.Sandbox.ShellJobsTest` and `Nest.Sandbox.ShellJobsNoticeTest` so the two
  cannot start jobs differently.
  """

  alias Nest.Sandbox.{Mounts, Paths}
  alias Nest.Sandbox.ShellJobs

  @doc """
  Start a job for `key` in `tmp`, as `shell-cmd` starts one.

  Options:

    * `:waiter` — the pid to register for the job's exit. Defaults to `nil`:
      `ShellJobs.start_job/1` otherwise registers *its caller*, which in
      production is the tool worker that will wait for the exit, but in a test is
      the test process. A test that wants a job nobody waits on — the case the
      owner notice (issue #163) exists for — gets that by saying nothing.
    * `:max_jobs` — the per-agent ceiling (default 1).
  """
  @spec start_owned_job!(Path.t(), ShellJobs.agent_key(), String.t(), keyword()) ::
          ShellJobs.job_id()
  def start_owned_job!(tmp, key, body, opts \\ []) do
    {:ok, id, _log} =
      ShellJobs.start_job(%{
        agent_key: key,
        agent_pid: self(),
        command: String.trim(body),
        script_sandbox: stage_script!(tmp, body),
        script_path: nil,
        mounts: Mounts.new(nil, tmp),
        max_jobs: Keyword.get(opts, :max_jobs, 1),
        waiter: Keyword.get(opts, :waiter)
      })

    id
  end

  @doc """
  Stage a job's script the way `ShellCmd` does, and return its in-sandbox path.

  A job's command line is the backend's to build (`Nest.Sandbox.Backend.job_spec/4`),
  and a job's output has to reach a log file *inside* the environment, which only
  the backend can arrange — so a test that starts a job directly has to have
  staged one, exactly as the tool does.
  """
  @spec stage_script!(Path.t(), String.t()) :: String.t()
  def stage_script!(tmp, body \\ "exit 0\n") do
    dir = Paths.stage_dir(tmp)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "run.sh"), body)
    Path.join(Paths.stage_dir_sandbox(tmp), "run.sh")
  end
end
