defmodule Nest.Sandbox.ShellJobsNamespaceLostTest do
  @moduledoc """
  Deterministic reconciliation of the jobs that die with a space's namespace
  holder (#224, chunk a): a holder death marks exactly that generation's running
  jobs dead with a distinct namespace-lost status, signals each owner once
  through the exit-notice path, leaves finished jobs and other generations
  alone, and does not double-finish when a job's own monitor `:DOWN` arrives
  late.
  """

  use ExUnit.Case, async: true

  import Eventually
  import ExUnit.CaptureLog
  import Nest.Test.TmpCleanup

  alias Nest.Sandbox.{Mounts, NamespaceHolder, Paths, ShellJobs}

  setup do
    space_id = System.unique_integer([:positive])
    ws = Path.join([File.cwd!(), "_build", "tmp", "nest_nl_ws_#{space_id}"])
    root = Path.join(System.tmp_dir!(), "nest_nl_#{space_id}")
    scratch = Path.join([root, "space", "agent"])
    File.mkdir_p!(ws)
    File.mkdir_p!(scratch)

    on_exit(fn ->
      NamespaceHolder.stop_space(space_id)
      rm_tmp!(ws, "nest_nl_ws_")
      rm_tmp!(root, "nest_nl_")
    end)

    %{space_id: space_id, ws: ws, scratch: scratch}
  end

  defp mounts(ctx), do: Mounts.new(ctx.ws, ctx.scratch, "bwrap", ctx.space_id, false)

  # Start a running background job that joins the space's holder, so it carries
  # the holder's generation. The test process stands in for the owning agent.
  defp start_job!(ctx, name, body, opts) do
    key = {ctx.space_id, name}

    {:ok, id, _log} =
      ShellJobs.start_job(%{
        agent_key: key,
        agent_pid: self(),
        command: String.trim(body),
        script_sandbox: stage!(ctx, body),
        script_path: nil,
        mounts: mounts(ctx),
        max_jobs: 1,
        waiter: Keyword.get(opts, :waiter)
      })

    {key, id}
  end

  defp stage!(ctx, body) do
    dir = Paths.stage_dir(ctx.scratch)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "run.sh"), body)
    Path.join(Paths.stage_dir_sandbox(ctx.scratch), "run.sh")
  end

  defp generation(space_id) do
    {:ok, %{generation: g}} = NamespaceHolder.ensure(space_id)
    g
  end

  defp job_field(id, field) do
    # allowlist: harness — the job record's killed_by/erl_pid have no public
    # accessor; the reconciliation's distinct status and the late-DOWN monitor
    # pid are read from the manager's own state, as the notice tests do.
    :sys.get_state(ShellJobs.name(), 1_000).jobs |> Map.fetch!(id) |> Map.fetch!(field)
  end

  describe "namespace_lost/2" do
    test "marks the generation's running job dead and signals its owner exactly once", ctx do
      g = generation(ctx.space_id)
      {key, id} = start_job!(ctx, "runner", "sleep 30\n", waiter: nil)
      assert [%{id: ^id, status: :running}] = ShellJobs.list(key)

      ShellJobs.namespace_lost(ctx.space_id, g)

      assert_receive {:"$gen_cast", {:shell_job_namespace_lost, ^id, 137, _output}}, 1_000
      assert [%{id: ^id, status: :exited, killed: true}] = ShellJobs.list(key)
      assert job_field(id, :killed_by) == :namespace
      assert job_field(id, :exit_code) == 137

      # One notice, the namespace-lost one — not the ordinary exit notice, and
      # not a second of either.
      refute_received {:"$gen_cast", {:shell_job_namespace_lost, _, _, _}}
      refute_received {:"$gen_cast", {:shell_job_exited, _, _, _}}
    end

    test "a waiter is told via the exit message, not a notice", ctx do
      g = generation(ctx.space_id)
      {key, id} = start_job!(ctx, "waited", "sleep 30\n", waiter: self())

      ShellJobs.namespace_lost(ctx.space_id, g)

      assert_receive {:shell_job_exit, ^id, 137}, 1_000
      assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)
      refute_received {:"$gen_cast", {:shell_job_namespace_lost, _, _, _}}
    end

    test "finished jobs and a newer generation's running jobs are untouched", ctx do
      g = generation(ctx.space_id)

      # A job of generation g that already finished on its own.
      {key_done, id_done} = start_job!(ctx, "done", "exit 0\n", waiter: nil)

      assert eventually(
               fn -> match?([%{status: :exited}], ShellJobs.list(key_done)) end,
               timeout: 1_000
             )

      # A running job of generation g.
      {key_run, id_run} = start_job!(ctx, "run", "sleep 30\n", waiter: nil)

      # Reconcile generation g while its holder is still alive: the running job
      # is marked namespace-lost, the finished one keeps its own exit code.
      ShellJobs.namespace_lost(ctx.space_id, g)
      assert_receive {:"$gen_cast", {:shell_job_namespace_lost, ^id_run, 137, _}}, 1_000
      assert [%{id: ^id_run, status: :exited}] = ShellJobs.list(key_run)
      assert [%{id: ^id_done, status: :exited, exit_code: 0}] = ShellJobs.list(key_done)

      # Restart the holder: a new generation with its own running job. A second
      # reconciliation of the OLD generation must leave the new job running.
      NamespaceHolder.stop_space(ctx.space_id)
      g2 = generation(ctx.space_id)
      refute g2 == g
      {key_new, id_new} = start_job!(ctx, "new", "sleep 30\n", waiter: nil)

      ShellJobs.namespace_lost(ctx.space_id, g)
      assert [%{id: ^id_new, status: :running}] = ShellJobs.list(key_new)
      assert [%{id: ^id_run, status: :exited}] = ShellJobs.list(key_run)
      refute_received {:"$gen_cast", {:shell_job_namespace_lost, ^id_new, _, _}}
    end

    test "the space-wide frame marks the dead job, so the space view updates (#225)", ctx do
      Phoenix.PubSub.subscribe(Nest.PubSub, "space:#{ctx.space_id}")
      g = generation(ctx.space_id)
      {_key, id} = start_job!(ctx, "spaceview", "sleep 30\n", waiter: nil)

      # The start is a space frame: the job is live in the space's list. The
      # broadcast happens inside the start call, so it is already in the mailbox.
      assert_receive {:space_jobs, %{space_id: sid, jobs: [%{id: ^id, status: :running}]}}, 500
      assert sid == ctx.space_id

      ShellJobs.namespace_lost(ctx.space_id, g)

      # The reconciliation's finish broadcasts like any other exit: the space
      # list shows the job dead — killed by the namespace, at 137 — without
      # the viewer joining the owner's agent channel.
      assert_receive {:space_jobs,
                      %{jobs: [%{id: ^id, status: :exited, killed: true, exit_code: 137}]}},
                     500
    end

    test "a late monitor DOWN does not finish or signal the job a second time", ctx do
      g = generation(ctx.space_id)
      {key, id} = start_job!(ctx, "late", "sleep 30\n", waiter: nil)

      ShellJobs.namespace_lost(ctx.space_id, g)
      assert_receive {:"$gen_cast", {:shell_job_namespace_lost, ^id, 137, _}}, 1_000

      # The job's exec port DOWN arrives after reconciliation. by_erl_pid/2
      # matches only running jobs, so this must be a no-op.
      erl_pid = job_field(id, :erl_pid)
      send(ShellJobs.name(), {:DOWN, make_ref(), :process, erl_pid, :killed})
      assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)

      refute_received {:"$gen_cast", {:shell_job_namespace_lost, _, _, _}}
      refute_received {:"$gen_cast", {:shell_job_exited, _, _, _}}
    end
  end

  describe "the holder-death path" do
    test "a holder that dies reconciles its jobs and restarts", ctx do
      {:ok, %{generation: g, holder_pid: holder_pid}} = NamespaceHolder.ensure(ctx.space_id)

      # The job marks itself ready once it has joined and is running, so the
      # holder is killed only after the join — not mid-start, which would fail
      # the job's own bwrap rather than test reconciliation.
      sandbox_scratch = Paths.sandbox_tmp_path(ctx.scratch)
      ready = Path.join(ctx.scratch, "ready")

      {key, id} =
        start_job!(ctx, "dying", "touch #{sandbox_scratch}/ready; sleep 30\n", waiter: nil)

      assert eventually(fn -> File.exists?(ready) end, timeout: 1_000)

      log =
        capture_log(fn ->
          # SIGKILL the verified holder child (PID 1 of its isolated namespace).
          System.cmd("kill", ["-9", holder_pid])

          # The job died with the namespace. Whether reconciliation or the job's
          # own monitor reaches it first, it is finished exactly once and its
          # owner is told exactly once (idempotency, #224 chunk a).
          assert_receive {:"$gen_cast", {notice, ^id, _code, _output}}, 1_500
          assert notice in [:shell_job_namespace_lost, :shell_job_exited]

          assert eventually(
                   fn ->
                     case NamespaceHolder.ensure(ctx.space_id) do
                       {:ok, %{generation: fresh}} -> fresh != g
                       :error -> false
                     end
                   end,
                   timeout: 1_500
                 )
        end)

      assert log =~ "restarting"
      # Dead exactly once, owner told exactly once — whichever of reconciliation
      # or the job's own monitor reached it first (the two are idempotent).
      assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)
      refute_received {:"$gen_cast", {:shell_job_namespace_lost, _, _, _}}
      refute_received {:"$gen_cast", {:shell_job_exited, _, _, _}}
    end
  end
end
