defmodule Nest.Sandbox.ShellJobsNoticeTest do
  @moduledoc """
  The manager's side of issue #163: a background job's exit is reported to the
  agent that owns it, and only when the agent is not already being told.

  Split from `Nest.Sandbox.ShellJobsTest` for the file cap, and because the
  delivery rule is one subject: who gets told, and who must not be.
  """

  use ExUnit.Case, async: true

  import Nest.Sandbox.ShellJobsTestHelpers

  alias Nest.Sandbox.ShellJobs

  setup do
    # A real space id: the manager's job-list broadcast is keyed by
    # `{space_id, name}`, so a key whose first element is not an integer would
    # silently disable it.
    key = {1, "agent-#{System.unique_integer([:positive])}"}
    root = Path.join(System.tmp_dir!(), "nest_jobs_#{System.unique_integer([:positive])}")
    tmp = Path.join([root, "space-1", elem(key, 1)])
    File.mkdir_p!(tmp)

    on_exit(fn ->
      ShellJobs.stop_all(key)
      if String.contains?(root, "nest_jobs_"), do: File.rm_rf(root)
    end)

    %{key: key, tmp: tmp}
  end

  # Issue #163: a job's exit used to reach only its waiters (and the UI), so an
  # agent that did not `shell-wait` was never told its job had ended. The manager
  # now casts the notice to the owning agent — a cast, because it must never
  # block on an agent to finish a job. The test process stands in for the agent,
  # so `GenServer.cast/2`'s `{:"$gen_cast", _}` frame is the observable; what a
  # real agent does with it is
  # `test/nest/agents/agent/shell_job_notice_test.exs`'s.
  describe "the owning agent is told its job exited (issue #163)" do
    test "a job that exits with no waiter delivers exactly one notice", %{key: key, tmp: tmp} do
      id = start_owned_job!(tmp, key, "echo done\n")

      assert_receive {:"$gen_cast", {:shell_job_exited, ^id, 0, "done\n"}}, 500

      # A call to the manager: `finish_job/3` has returned, so everything it was
      # going to send is in the mailbox. One notice, not two.
      assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)
      refute_received {:"$gen_cast", {:shell_job_exited, _, _, _}}
    end

    test "a waiter suppresses the notice: a wait is the agent asking to be told", %{
      key: key,
      tmp: tmp
    } do
      id = start_owned_job!(tmp, key, "sleep 30\n")
      assert :ok = ShellJobs.subscribe(key, id, self())
      # Registered before the kill, so the exit is reached with a waiter — the
      # waiter list is the manager's own state, so this is not a race.
      assert self() in waiters(id)

      # A sibling's kill notifies the owner in general (it did not ask, so it is
      # the one it did not mean to lose); the waiter is what suppresses it here.
      assert {:ok, _key} = ShellJobs.kill_space(elem(key, 0), id)

      assert_receive {:shell_job_exit, ^id, _code}, 500
      assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)
      refute_received {:"$gen_cast", {:shell_job_exited, _, _, _}}
    end

    test "a sibling's kill still notifies the owner", %{key: key, tmp: tmp} do
      id = start_owned_job!(tmp, key, "sleep 30\n")

      assert {:ok, _key} = ShellJobs.kill_space(elem(key, 0), id)

      assert_receive {:"$gen_cast", {:shell_job_exited, ^id, code, ""}}, 500
      assert is_integer(code)
    end

    test "a job finished by the kill fallback is not finished again by its port's late DOWN",
         %{key: key, tmp: tmp} do
      id = start_owned_job!(tmp, key, "sleep 30\n")

      # A sibling's kill is not suppressed, so the notice is the observable.
      assert {:ok, _key} = ShellJobs.kill_space(elem(key, 0), id)

      # The fallback fires first, because the port's DOWN did not arrive in
      # time. A call to the manager is the barrier: the fallback has run.
      send(ShellJobs.name(), {:kill_finalize, id})
      assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)

      # Then the port's DOWN arrives. `finish_job/3` leaves `erl_pid` in place,
      # so `by_erl_pid/2` used to match the finished job and finish it again —
      # a second notice, and a second turn on the same result.
      # allowlist: harness — the job's exec port, to deliver its late DOWN
      erl_pid =
        :sys.get_state(ShellJobs.name(), 500).jobs |> Map.fetch!(id) |> Map.fetch!(:erl_pid)

      send(ShellJobs.name(), {:DOWN, make_ref(), :process, erl_pid, :killed})

      # A call, so the DOWN has been handled when it returns.
      assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)
      assert_received {:"$gen_cast", {:shell_job_exited, ^id, _code, _output}}
      refute_received {:"$gen_cast", {:shell_job_exited, _, _, _}}
    end

    test "a waiter registered at start suppresses the notice even for an immediate exit", %{
      key: key,
      tmp: tmp
    } do
      # `start_job/1` registers its caller as the waiter in the callback that
      # creates the job, so the manager cannot process the exit before it. The
      # window between `start_job` returning and a later `subscribe/3` is what
      # produced *two* reports of one exit: the inline tool result and a notice.
      id = start_owned_job!(tmp, key, "exit 0\n", waiter: self())

      assert_receive {:shell_job_exit, ^id, 0}, 500
      assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)
      refute_received {:"$gen_cast", {:shell_job_exited, _, _, _}}
    end

    test "unsubscribe answers with the job's state at removal", %{key: key, tmp: tmp} do
      # A waiter that times out cannot tell whether the exit landed in the
      # window between its `after` firing and its unsubscribe being handled.
      # The reply is the one answer to that, so the window has no lost exit.
      id = start_owned_job!(tmp, key, "sleep 30\n", waiter: nil)
      assert :running = ShellJobs.unsubscribe(key, id, self())

      assert {:ok, _key} = ShellJobs.kill_space(elem(key, 0), id)
      assert_receive {:"$gen_cast", {:shell_job_exited, ^id, code, _output}}, 500

      assert {:exited, ^code} = ShellJobs.unsubscribe(key, id, self())
    end

    test "the owner's own kill delivers no notice", %{key: {space_id, name} = key, tmp: tmp} do
      Phoenix.PubSub.subscribe(Nest.PubSub, "agent:#{space_id}:#{name}")
      id = start_owned_job!(tmp, key, "sleep 30\n")
      # `:start_job` broadcasts before it replies, and the local PubSub sends to
      # its subscribers from the broadcasting process, so the frame is already
      # here.
      assert_received {:shell_jobs, %{jobs: [%{id: ^id, status: :running}]}}

      assert :ok = ShellJobs.kill(key, id)
      assert_received {:shell_jobs, %{jobs: [%{id: ^id, killed: true}]}}

      # The exit frame is `finish_job/3`'s last act — after the notice would have
      # been sent — so it is the barrier for the absence below, not a clock.
      assert_receive {:shell_jobs, %{jobs: [%{id: ^id, status: :exited}]}}, 500

      # No waiter, so nothing else could tell the owner anything — and the tool
      # call that asked for the kill already reports the exit, so the manager
      # must stay quiet.
      assert [%{id: ^id, status: :exited, killed: true}] = ShellJobs.list(key)
      refute_received {:"$gen_cast", {:shell_job_exited, _, _, _}}
    end
  end

  defp waiters(id), do: ShellJobs.waiters(id, 1_000)
end
