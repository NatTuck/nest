defmodule Nest.Sandbox.ShellJobsSpaceViewTest do
  @moduledoc """
  The space-wide job surface (#225): the `{:space_jobs, _}` frame every job
  change broadcasts on the space's topic, and `output_space/2`, the log read
  the space view renders for any agent's job.

  The frame is what keeps the lobby's space job panel live without joining any
  agent channel; the holder-death half of that contract (a job dying with its
  namespace reaches the space list too) is `ShellJobsNamespaceLostTest`'s.
  """

  use ExUnit.Case, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs
  alias Nest.Sandbox.ShellJobs.Owned

  setup do
    # A real, unique space id: the broadcast is keyed by `{space_id, name}`,
    # and a non-integer space would silently disable it. Unique so a concurrent
    # test's jobs cannot appear in this space's frames.
    space_id = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "nest_space_view_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> rm_tmp!(root, "nest_space_view_") end)

    %{space_id: space_id, root: root}
  end

  # A running foreground-style job (#174): the real registration path, with no
  # OS process behind it — the record is what the space view renders.
  defp register!(ctx, name, command) do
    key = {ctx.space_id, name}
    scratch = Path.join([ctx.root, "space-#{ctx.space_id}", name])
    File.mkdir_p!(scratch)

    on_exit(fn -> ShellJobs.stop_all(key) end)

    assert {:ok, job} =
             ShellJobs.register_owned(%{
               agent_key: key,
               command: command,
               mounts: Mounts.new(nil, scratch, "none", ctx.space_id),
               os_pid: 1
             })

    job
  end

  test "the space frame carries every agent's jobs, running first, on every change", ctx do
    Phoenix.PubSub.subscribe(Nest.PubSub, "space:#{ctx.space_id}")

    alice = register!(ctx, "alice", "sleep 30")

    # The registration itself is a space frame: the job is live in the space
    # list, named by its owner. The broadcast happens inside the call above,
    # so the frame is already in the mailbox.
    assert_receive {:space_jobs,
                    %{space_id: sid, jobs: [%{id: id, agent: "alice", status: :running}]}},
                   500

    assert sid == ctx.space_id
    assert id == alice.id

    bob = register!(ctx, "bob", "echo hi")

    # Both agents' jobs in one frame, newest running first — the same order
    # `list_space/1` answers a refresh with.
    assert_receive {:space_jobs, %{jobs: jobs}}, 500
    assert Enum.map(jobs, & &1.id) == [bob.id, alice.id]
    assert Enum.map(jobs, & &1.agent) == ["bob", "alice"]

    # A finish is a space frame too: the finished job stays listed (a refresh
    # and `shell-wait` still answer for it) but the running one leads.
    :ok = ShellJobs.finish_owned(alice.id, 0)

    assert_receive {:space_jobs,
                    %{jobs: [%{id: bid, status: :running}, %{id: aid, status: :exited}]}},
                   500

    assert bid == bob.id
    assert aid == alice.id
    assert ShellJobs.list_space(ctx.space_id) |> Enum.map(& &1.id) == [bob.id, alice.id]
  end

  test "output_space reads any agent's log in the space, and refuses outside it", ctx do
    job = register!(ctx, "reader", "echo hello")
    assert :ok = Owned.append(job, "hello\n")

    # The space-scoped read: the owner's key is not needed, only the space.
    assert ShellJobs.output_space(ctx.space_id, job.id) == {:ok, "hello\n"}
    # The owner-scoped read still agrees — one log, two doors.
    assert ShellJobs.output({ctx.space_id, "reader"}, job.id) == {:ok, "hello\n"}

    # Another space cannot reach the job, and neither can an id nobody has.
    assert ShellJobs.output_space(ctx.space_id + 1, job.id) == {:error, :not_found}
    assert ShellJobs.output_space(ctx.space_id, "job-999999") == {:error, :not_found}
  end
end
