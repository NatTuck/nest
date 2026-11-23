defmodule NestWeb.LobbyChannelSpaceJobsTest do
  @moduledoc """
  The space-wide job view's transport (`NestWeb.LobbyChannel.SpaceJobs`, #225):
  the `init` payload's per-space lists, the `space:jobs` push a job change
  becomes, and the refresh / kill / log pushes.

  The jobs are real registrations in the global manager (`register_owned`, the
  foreground-call path of #174), so the whole path is exercised: manager
  broadcast → space topic → the channel's subscription → this client's push.
  No agent process is needed — a job's owner here is the test process, which
  is what makes the kill's `{:kill_job, _}` delivery and the finish observable
  without a running command.
  """

  use NestWeb.ChannelCase, async: true

  import Nest.Test.TmpCleanup

  alias Nest.Accounts
  alias Nest.Accounts.AuthToken
  alias Nest.AddressTestHelpers
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Sandbox.Mounts
  alias Nest.Sandbox.ShellJobs
  alias Nest.Sandbox.ShellJobs.Owned
  alias Nest.Spaces

  setup do
    space = AddressTestHelpers.space_with_human("alice")
    alice = Accounts.get_user(space.created_by_user_id)
    _bob = AddressTestHelpers.human("bob")

    root = Path.join(System.tmp_dir!(), "nest_lobby_jobs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn -> rm_tmp!(root, "nest_lobby_jobs_") end)

    %{space: space, alice: alice, root: root, token: AuthToken.sign(alice.id)}
  end

  # A running job in `space`, owned by the test process. Its scratch is under
  # the test's own root; `stop_all` on exit drops the record (the manager's
  # scratch cleanup names the agent's own directory, not this fixture's).
  defp register!(ctx, name, command) do
    key = {ctx.space.id, name}
    scratch = Path.join([ctx.root, name])
    File.mkdir_p!(scratch)

    on_exit(fn -> ShellJobs.stop_all(key) end)

    assert {:ok, job} =
             ShellJobs.register_owned(%{
               agent_key: key,
               command: command,
               mounts: Mounts.new(nil, scratch, "none", ctx.space.id),
               os_pid: 1
             })

    job
  end

  defp join(token) do
    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => token})
    {:ok, _reply, socket} = subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

    # The join's own pushes, so they cannot be mistaken for a frame under test.
    # `broken_agents_updated` is also the barrier for the async task the join
    # starts (it does DB work on this test's sandbox connection).
    assert_push "init", %{}
    assert_push "broken_agents_updated", %{broken_agents: _}, 1_000
    socket
  end

  test "init carries every visible space's job list, empty ones included", ctx do
    job = register!(ctx, "early", "sleep 30")

    # A second space of alice's with no jobs: its entry is an empty list, not
    # an absence — the panel renders "no jobs" from a known empty read.
    {:ok, empty_space} =
      Spaces.create_space(ctx.alice.id, %{
        name: "empty-#{System.unique_integer([:positive])}",
        slug: "empty-#{System.unique_integer([:positive])}",
        workspace_path: AgentTestHelpers.default_test_workspace()
      })

    {:ok, connected} = connect(NestWeb.UserSocket, %{"token" => ctx.token})
    {:ok, _reply, _socket} = subscribe_and_join(connected, NestWeb.LobbyChannel, "lobby")

    assert_push "init", %{space_jobs: entries}
    assert_push "broken_agents_updated", %{broken_agents: _}, 1_000

    entry = Enum.find(entries, &(&1.space_id == ctx.space.id))
    assert [%{id: id, agent: "early", status: :running}] = entry.jobs
    assert id == job.id

    assert %{space_id: empty_id, jobs: []} = Enum.find(entries, &(&1.space_id == empty_space.id))
    assert empty_id == empty_space.id

    # Only the user's own spaces: bob's (none here) and other users' never ride
    # this payload — the same visible set the subscriptions are built from.
    assert Enum.all?(entries, &(&1.space_id in [ctx.space.id, empty_space.id]))
  end

  test "space_jobs refresh answers the space's jobs; outsiders and bad payloads are refused",
       ctx do
    socket = join(ctx.token)
    job = register!(ctx, "runner", "sleep 30")

    ref = push(socket, "space_jobs", %{"space_id" => ctx.space.id})
    assert_reply ref, :ok, %{jobs: [listed]}, 500
    assert listed.id == job.id
    assert listed.agent == "runner"
    assert listed.status == :running

    bob = Accounts.get_user_by_username("bob")
    bob_socket = join(AuthToken.sign(bob.id))

    ref = push(bob_socket, "space_jobs", %{"space_id" => ctx.space.id})
    assert_reply ref, :error, %{"reason" => "forbidden"}, 500

    ref = push(socket, "space_jobs", %{"space_id" => -1})
    assert_reply ref, :error, %{"reason" => "not_found"}, 500

    ref = push(socket, "space_jobs", %{})
    assert_reply ref, :error, %{"reason" => "invalid_payload"}, 500
  end

  test "a job change becomes a space:jobs push, from start to finish", ctx do
    _socket = join(ctx.token)

    job = register!(ctx, "live", "sleep 30")

    assert_push "space:jobs", %{space_id: sid, jobs: [pushed]}, 500
    assert sid == ctx.space.id
    assert pushed.id == job.id
    assert pushed.status == :running

    :ok = ShellJobs.finish_owned(job.id, 0)

    assert_push "space:jobs", %{jobs: [%{id: id, status: :exited, exit_code: 0}]}, 500
    assert id == job.id
  end

  test "kill_space_job stops any agent's job, names its owner, and the finish is pushed", ctx do
    socket = join(ctx.token)
    job = register!(ctx, "sibling", "sleep 30")

    ref = push(socket, "kill_space_job", %{"space_id" => ctx.space.id, "id" => job.id})
    assert_reply ref, :ok, %{agent: "sibling"}, 500

    # The kill marks the job and tells its owner (the test process) to stop;
    # the frame says so while the owner's finish is still pending.
    assert_push "space:jobs", %{jobs: [%{id: id, killed: true, status: :running}]}, 500
    assert id == job.id
    assert_received {:kill_job, ^id}

    :ok = ShellJobs.finish_owned(job.id, 137)

    assert_push "space:jobs",
                %{jobs: [%{id: ^id, status: :exited, killed: true, exit_code: 137}]},
                500

    # An id nobody has, a space the caller does not own, and a payload that
    # cannot be routed are all refused.
    ref = push(socket, "kill_space_job", %{"space_id" => ctx.space.id, "id" => "job-999999"})
    assert_reply ref, :error, %{"reason" => "not_found"}, 500

    bob = Accounts.get_user_by_username("bob")
    bob_socket = join(AuthToken.sign(bob.id))

    ref = push(bob_socket, "kill_space_job", %{"space_id" => ctx.space.id, "id" => job.id})
    assert_reply ref, :error, %{"reason" => "forbidden"}, 500

    ref = push(socket, "kill_space_job", %{"space_id" => ctx.space.id})
    assert_reply ref, :error, %{"reason" => "invalid_payload"}, 500
  end

  test "space_job_log reads the job's output; outsiders and unknown ids are refused", ctx do
    socket = join(ctx.token)
    job = register!(ctx, "logger", "echo hello")
    assert :ok = Owned.append(job, "hello\n")

    ref = push(socket, "space_job_log", %{"space_id" => ctx.space.id, "id" => job.id})
    assert_reply ref, :ok, %{content: "hello\n"}, 500

    ref = push(socket, "space_job_log", %{"space_id" => ctx.space.id, "id" => "job-999999"})
    assert_reply ref, :error, %{"reason" => "not_found"}, 500

    bob = Accounts.get_user_by_username("bob")
    bob_socket = join(AuthToken.sign(bob.id))

    ref = push(bob_socket, "space_job_log", %{"space_id" => ctx.space.id, "id" => job.id})
    assert_reply ref, :error, %{"reason" => "forbidden"}, 500

    ref = push(socket, "space_job_log", %{"id" => job.id})
    assert_reply ref, :error, %{"reason" => "invalid_payload"}, 500
  end
end
