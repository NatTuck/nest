defmodule Nest.Agents.Agent.BroadcastsLifecycleTest do
  @moduledoc """
  The `agent:created` and `agent:stopped` lifecycle frames (#72, #73).

  `agent:created`'s payload is built in one place, so its shape is a property of
  the builder rather than of which caller sent it. `agent:stopped` is emitted by
  the agent itself, from inside `terminate/2`, so the frame is a fact about a
  process that has stopped rather than a prediction made when a stop was asked
  for.
  """

  use Nest.DataCase, async: true

  import Nest.Agents.AgentTestHelpers
  import Nest.Sandbox.ShellJobsTestHelpers
  import Nest.Test.TmpCleanup

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Supervisor
  alias Nest.Sandbox.ShellJobs

  # The keys `Broadcasts.created_payload/2` promises, as the client reads them
  # (`assets/js/store/slices/catalog.js`'s `normalizeAgent/1`).
  @created_keys ~w(name space_id model status vocation parentId parentName depth runningJobs)

  describe "the agent:created payload (#72)" do
    test "carries the same keys whichever caller built it" do
      # The two callers' attrs as they are really passed: the lobby's
      # space-creation path, which knows the vocation, and `SubAgent`'s spawn
      # path, which knows the tree position.
      from_lobby =
        Broadcasts.created_payload(7,
          name: "root",
          model: %{name: "m", provider: "p"},
          vocation: "programmer"
        )

      from_spawn =
        Broadcasts.created_payload(7,
          name: "child",
          model: %{name: "m"},
          parent_id: 3,
          parent_name: "root",
          depth: 1
        )

      # This is the assertion #72 exists for. The two frames used to be built
      # by their callers, so a key added for one and not the other was invisible
      # — the client read both as one shape. A key that appears for one caller
      # and not the other now fails here.
      assert Enum.sort(Map.keys(from_lobby)) == Enum.sort(Map.keys(from_spawn))
      assert Enum.sort(Map.keys(from_lobby)) == Enum.sort(@created_keys)
    end

    test "fills the documented defaults and states an absent field as nil" do
      payload = Broadcasts.created_payload(7, name: "child", model: nil)

      assert payload["name"] == "child"
      assert payload["space_id"] == 7
      # A freshly created agent is idle, and a root.
      assert payload["status"] == "idle"
      assert payload["depth"] == 0

      # Present and nil, rather than absent: a caller that has nothing to say
      # about a field must not make that field indistinguishable from one the
      # client has never been told about. That every one of these keys is
      # present at all — for a caller that omits five of them — is pinned by the
      # key-set assertion in the test above; these pin the *value* it defaults
      # to.
      assert payload["vocation"] == nil
      assert payload["model"] == nil
      assert payload["parentId"] == nil
    end

    test "runs the model through the same model_payload/1 the status broadcast uses" do
      payload = Broadcasts.created_payload(7, name: "root", model: %{name: "m", provider: "p"})

      # Atom keys become strings, exactly as they do on a `chat:status` frame.
      # So a root agent's `agent:created` now carries the same model shape a
      # subagent's does, instead of the narrower name/provider pair it used to.
      assert payload["model"] == %{"name" => "m", "provider" => "p"}
    end
  end

  describe "the running background-job count (#175)" do
    test "is 0 with no jobs, the running count with some, and 0 again once they exit" do
      # A real space id and a real job: the count is read from the job manager
      # (#175), so a payload test that never starts one would pass against a
      # hardcoded zero.
      space_id = System.unique_integer([:positive])
      name = "worker-#{System.unique_integer([:positive])}"
      key = {space_id, name}
      # The real scratch shape, `<root>/space-<id>/<agent-name>`: the space dir
      # is what the sandbox binds at `/tmp`, and staging a command transcript
      # under a flat dir is refused (`Paths.scratch_root/1`).
      root = unique_tmp("nest_jobs_created_")
      tmp = Path.join([root, "space-#{space_id}", name])
      File.mkdir_p!(tmp)

      on_exit(fn ->
        ShellJobs.stop_all(key)
        rm_tmp!(root, "nest_jobs_created_")
      end)

      # A new agent has no jobs, and the key is present anyway — the whole
      # point of building every row from one place (#72).
      assert %{"runningJobs" => 0} = Broadcasts.created_payload(space_id, name: name)

      id = start_owned_job!(tmp, key, "sleep 30\n")
      assert %{"runningJobs" => 1} = Broadcasts.created_payload(space_id, name: name)

      assert :ok = ShellJobs.subscribe(key, id, self())
      assert :ok = ShellJobs.kill(key, id)
      assert_receive {:shell_job_exit, ^id, _code}, 500

      # A finished job is kept for `shell-list`/`shell-wait`, so it is still
      # listed — but it is not running, and the sidebar shows running ones.
      assert [%{id: ^id, status: :exited}] = ShellJobs.list(key)
      assert %{"runningJobs" => 0} = Broadcasts.created_payload(space_id, name: name)
    end
  end

  describe "the agent:stopped frame (#73)" do
    test "is broadcast when an agent stops, including on an archive" do
      # The agent is linked to this process and the stop ends it, so an
      # untrapped `:shutdown` would take the test with it.
      Process.flag(:trap_exit, true)

      {pid, name} = start_agent(default_attrs())
      space_id = current_space_id()
      Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.space_topic(space_id))

      ref = Process.monitor(pid)
      # An archive stops the agent through the same `Supervisor.stop_one/3` a
      # plain Stop uses, so this covers both entry points: the frame is emitted
      # from inside `Agent.terminate/2`, which every stop path runs.
      assert :ok = Supervisor.archive_agent(space_id, name)
      # The `:DOWN` is the fence, and it is sound rather than merely convenient:
      # the frame is emitted inside `terminate/2`, which runs before the process
      # exits, so it is already in this mailbox by the time the `:DOWN` arrives.
      # No clock is involved, so the assertions below are `assert_received`, not
      # `assert_receive`; the bound on the `:DOWN` is only a failure detector and
      # it is the 500 ms SMELLS.md cap.
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500

      # An archive ends the agent, so it reports the stop *and* the archive.
      # The pair is not contradictory — an archived agent is also a stopped one
      # — and the client's handler for the stop only touches rows still in its
      # active list, so a stop arriving after the archive is a no-op instead of
      # a resurrection. Both frames are asserted here because that ordering is
      # the whole reason the decision is safe.
      assert_received {:agent_stopped, %{"space_id" => ^space_id, "name" => ^name}}
      assert_received {:agent_archived, %{"space_id" => ^space_id, "name" => ^name}}
    end
  end

  # A fresh path under the OS temp dir, tagged so `rm_tmp!/2` can recognise it.
  defp unique_tmp(marker) do
    Path.join(System.tmp_dir!(), "#{marker}#{System.unique_integer([:positive])}")
  end

  defp default_attrs do
    %{model: %{name: "qwen3.5-plus"}, vocation_id: programmer_vocation_id_for_test()}
  end
end
