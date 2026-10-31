defmodule Nest.Agents.SupervisorSubagentTest do
  @moduledoc """
  Tests for `Supervisor.start_agent_with_parent/2` and
  the cascade termination walk.

  This module uses `Nest.DataCase` because spawning a
  child writes a new `agents` row with `parent_id` /
  `depth` set; it also exercises the on-demand-load
  path (`build_attrs_for_start`) when restoring the
  parent later. Tests run `async: true` — the sandbox
  rollback handles DB cleanup at test exit, so each
  test's row inserts are isolated.

  ## What's covered

    * `start_agent_with_parent/2` returns `{:ok,
      child_name}` and the new row has `parent_id` =
      parent's integer `agents.id`, `depth` =
      `parent.depth + 1`.
    * The child's runtime carries `parent_name`
      matching the parent's `name` (so the child can
      dispatch `:child_completed` to the right parent
      without a pid lookup).
    * `Supervisor.stop_agent/2` stops only the named agent;
      idle children (not in `pending_children`) survive.
  """
  use Nest.DataCase, async: true

  import Nest.Test.TmpCleanup

  alias Ecto.Adapters.SQL.Sandbox
  alias Nest.Agents
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.AgentTestLifecycle
  alias Nest.Agents.ChildRegistry
  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Sandbox.Mounts
  alias Nest.Spaces
  alias Nest.Vocations

  setup do
    case Process.whereis(ChildRegistry) do
      nil -> start_supervised!(ChildRegistry.child_spec())
      _pid -> :ok
    end

    {:ok, _space_id} = AgentTestHelpers.create_test_space()
    {:ok, vid} = upsert_test_vocation()
    {:ok, vid: vid}
  end

  describe "start_agent_with_parent/2" do
    test "a failed clone leaves no orphan row, and a later clone still starts", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)
      space_id = AgentTestHelpers.current_space_id()
      space_dir = TmpSpace.space_dir(space_id, "bwrap")

      # A clone's name is generated, so the blocker has to catch *any* name:
      # replacing the space directory with a file makes `TmpSpace.create/3`'s
      # `File.mkdir_p!` raise `File.Error` for whichever child name comes out,
      # so the clone's `init/1` fails before the process starts.
      rm_tmp!(space_dir, Path.join("nest", System.pid()))
      File.write!(space_dir, "not a directory")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _reason} =
                   Supervisor.start_agent_with_parent(parent_state, "do a thing")
        end)

      # Only the parent's row is left: the clone's pre-spawned row (and its
      # system message) is gone, so nothing is left blocking a name.
      assert agent_count(space_id) == 1
      assert log =~ "failed to start"

      # With the space dir back, a clone starts normally.
      File.rm!(space_dir)
      File.mkdir_p!(space_dir)

      assert {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "do a thing")
      assert {:ok, _row} = Persistence.fetch_agent(space_id, child_name)
      assert agent_count(space_id) == 2

      safe_stop(space_id, child_name)
    end

    test "spawns a child whose row carries the parent's id and depth+1", %{vid: vid} do
      {:ok, parent_name, parent_pid, parent_id} = start_root_parent(vid)
      space_id = AgentTestHelpers.current_space_id()
      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_name} =
        Supervisor.start_agent_with_parent(parent_state, "do a thing")

      {:ok, child_row} = Persistence.fetch_agent(space_id, child_name)
      assert child_row.parent_id == parent_id
      assert child_row.depth == 1

      # Owns the parent's name on the runtime.
      info = Nest.Agents.Agent.get_public_info(via_registry(child_name))
      assert info.parent_name == parent_name
      assert info.parent_id == parent_id

      on_exit(fn -> safe_stop(space_id, child_name) end)
    end

    test "clone with a model override gives the child the override model", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)
      override = %{name: "pegasus-default-only", provider: "pegasus"}

      {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "do it", override)

      assert Nest.Agents.Agent.get_public_info(via_registry(child_name), 1_000).model == override

      space_id = AgentTestHelpers.current_space_id()
      on_exit(fn -> safe_stop(space_id, child_name) end)
    end

    test "clone without a model override inherits the parent's model", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "do it")

      assert Nest.Agents.Agent.get_public_info(via_registry(child_name), 1_000).model ==
               parent_state.model

      space_id = AgentTestHelpers.current_space_id()
      on_exit(fn -> safe_stop(space_id, child_name) end)
    end

    # The clone's environment is the *space's*, resolved from the row like every
    # other start (`Persistence.build_agent_attrs/1`). `PreSpawn.inherited_attrs/4`
    # copies the backend and the network access from the parent's mounts but not
    # the workspace, so without that call the clone started with no workspace at
    # all: its own spawn check read the missing value and refused every child with
    # `:workspace_required`, and every command it ran began in the sandbox's
    # `/tmp`. A clone therefore could not do the one thing a clone is for.
    test "a clone carries the space's workspace, so it can spawn a child", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)
      space_id = AgentTestHelpers.current_space_id()
      workspace = Spaces.environment(space_id).workspace_path

      {:ok, clone} = Supervisor.start_agent_with_parent(parent_state, "carry on")
      on_exit(fn -> safe_stop(space_id, clone) end)

      # The value its tools resolve against and its prompt states — nil before
      # the fix, which is what the UI's `init` frame carries too.
      assert {:ok, %{workspace_path: ^workspace}} = Agents.get_info(space_id, clone)

      # The clone's own spawn request: the funnel both `agents-spawn` and
      # `agents-batch` reach (`{:spawn_agent_request, pid, opts}`). It runs in the
      # clone's process, which needs this test's sandbox connection for its DB
      # writes. The bound is the suite's test-side one (see
      # `SubAgentToolsHelpers`).
      {:ok, clone_pid} = Supervisor.get_agent(space_id, clone)
      Sandbox.allow(Nest.Repo, self(), clone_pid)
      grandchild = "grandchild-#{System.unique_integer([:positive])}"

      assert {:ok, ^grandchild} =
               GenServer.call(
                 clone_pid,
                 {:spawn_agent_request, self(),
                  %{
                    name: grandchild,
                    vocation: AgentTestHelpers.vocation_slug_for_test(),
                    query: ""
                  }},
                 1_000
               )

      on_exit(fn -> safe_stop(space_id, grandchild) end)

      assert {:ok, %{workspace_path: ^workspace}} = Agents.get_info(space_id, grandchild)
    end
  end

  describe "a clone's vocation" do
    # `agents-spawn`'s `vocation` is a documented argument for every spawn, and
    # the clone branch used to drop it: the model asked for a specialist and got
    # a copy of itself, while the tool reported success. An *omitted* vocation is
    # the clone's own case — it inherits the parent's, which is what makes a
    # clone a clone (a fresh spawn's omitted vocation means the blueprint's
    # default instead).
    test "a named vocation is the child's, and an omitted one is the parent's", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)
      space_id = AgentTestHelpers.current_space_id()
      {:ok, specialist} = upsert_specialist_vocation()

      {:ok, inherited} = Supervisor.start_agent_with_parent(parent_state, "carry on")
      on_exit(fn -> safe_stop(space_id, inherited) end)

      assert {:ok, %{vocation_id: ^vid}} = Persistence.fetch_agent(space_id, inherited)

      assert %{vocation_id: ^vid} =
               Nest.Agents.Agent.get_public_info(via_registry(inherited), 1_000)

      {:ok, named} =
        Supervisor.start_agent_with_parent(parent_state, "carry on", nil,
          vocation: specialist.slug
        )

      on_exit(fn -> safe_stop(space_id, named) end)

      # The row and the live state agree: the live vocation is what composes the
      # child's prompt and tool list, so a row-only assertion would let a child
      # run with one vocation's identity and another's tools.
      specialist_id = specialist.id
      assert {:ok, %{vocation_id: ^specialist_id}} = Persistence.fetch_agent(space_id, named)

      assert %{vocation_id: ^specialist_id} =
               Nest.Agents.Agent.get_public_info(via_registry(named), 1_000)
    end

    test "a vocation that cannot be honoured is refused, and no row is written", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)
      space_id = AgentTestHelpers.current_space_id()

      # A clone's named vocation goes through the same resolution (and so the same
      # blueprint whitelist) as a fresh spawn's — `SpawnVocation.resolve/2` — and a
      # name that cannot be honoured is refused rather than dropped, which is what
      # the clone branch used to do with every name.
      assert {:error, {:vocation_not_found, "no-such-vocation"}} =
               Supervisor.start_agent_with_parent(parent_state, "carry on", nil,
                 vocation: "no-such-vocation"
               )

      # Refused before the row: only the parent exists.
      assert agent_count(space_id) == 1
    end
  end

  describe "stop_agent/2" do
    test "stops only the named agent — a registered idle child survives", %{vid: vid} do
      {:ok, parent_name, parent_pid, _} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)
      space_id = AgentTestHelpers.current_space_id()

      {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "a")

      # `Supervisor.stop_agent/2` fires `Process.exit/2` and returns before the
      # process is gone, so the parent's own `:DOWN` — monitored first, so the
      # event can't be missed — is the fence that proves it died. The child's
      # registry hit below is only meaningful once that death is decided.
      parent_ref = Process.monitor(parent_pid)

      :ok = Supervisor.stop_agent(space_id, parent_name)

      assert_receive {:DOWN, ^parent_ref, :process, ^parent_pid, _reason}, 1_000

      # Idle children (not in `pending_children`) are left running.
      assert {:ok, _pid} = AgentsRegistry.lookup(space_id, child_name)

      on_exit(fn -> safe_stop(space_id, child_name) end)
    end
  end

  describe "parent_name restoration on agent restore" do
    # Phase 1 followup F1: after `Persistence.build_attrs_for_start/2`
    # loads a child agent from the DB, the returned attrs must carry
    # `parent_name` so the chat_turn_handler's `:child_completed`
    # notification reaches the parent. Without it the child
    # silently vanishes from the parent's view after a BEAM
    # restart, even though the DB row's `parent_id` is intact.
    test "child's restored attrs carry the parent's name", %{vid: vid} do
      {:ok, parent_name, parent_pid, _parent_id} = start_root_parent(vid)
      parent_state = read_parent_state(parent_name, parent_pid)

      {:ok, child_name} = Supervisor.start_agent_with_parent(parent_state, "child")
      space_id = AgentTestHelpers.current_space_id()
      on_exit(fn -> safe_stop(space_id, child_name) end)

      # Now exercise the restore path: `build_attrs_for_start/2`
      # is what `Supervisor.fetch_or_start_agent/2` calls when
      # the BEAM restarts. The DB row has `parent_id` set; the
      # returned attrs must also carry `parent_name`.
      {:ok, attrs} = Persistence.build_attrs_for_start(space_id, child_name)
      assert attrs.parent_name == parent_name
    end

    test "root agent's restored attrs have parent_name nil", %{vid: vid} do
      {:ok, parent_name, _parent_pid, _} = start_root_parent(vid)

      {:ok, attrs} =
        Persistence.build_attrs_for_start(AgentTestHelpers.current_space_id(), parent_name)

      assert attrs.parent_name == nil
    end
  end

  # ---- helpers ----

  defp upsert_test_vocation do
    {:ok, %Vocations.Vocation{id: vid}} =
      Vocations.upsert_vocation(%{
        name: "Subagent Supervisor Test Vocation #{System.unique_integer([:positive])}",
        description: "Subagent test default",
        system_prompt: "You are a test agent.",
        tools: ["context", "agents"]
      })

    {:ok, vid}
  end

  # A distinct vocation for a clone that names one. Its tools differ from the
  # parent's on purpose: the live vocation is what composes the child's tool
  # list, so the assertion has to see the specialist, not just its id.
  defp upsert_specialist_vocation do
    Vocations.upsert_vocation(%{
      name: "Subagent Clone Specialist #{System.unique_integer([:positive])}",
      description: "A specialist a clone can be given",
      system_prompt: "You are a specialist.",
      tools: ["context"]
    })
  end

  defp start_root_parent(vid) do
    name = "parent-#{System.unique_integer([:positive])}"
    model = %{name: "qwen3.5-plus", provider: "model-studio"}

    # Insert the agent row first (in the test process —
    # the agent's GenServer writes via the same
    # connection via `$callers`).
    {:ok, row} =
      Persistence.insert_agent(%{
        space_id: AgentTestHelpers.current_space_id(),
        name: name,
        model: model,
        vocation_id: vid
      })

    # Start the agent under the application supervisor
    # so `Supervisor.stop_agent/2` can
    # terminate it via the same DynamicSupervisor.
    attrs = %{
      space_id: AgentTestHelpers.current_space_id(),
      name: name,
      model: model,
      vocation_id: vid,
      vocation: Vocations.get_vocation(vid),
      parent_id: nil,
      depth: 0,
      # `Init.build_state/2` requires it (see `Nest.Sandbox.Backend`).
      sandbox_backend: "bwrap",
      network_access: true
    }

    {:ok, parent_pid} = Supervisor.start_under_test(attrs)

    Mimic.allow(Nest.LLM.MockClient, self(), parent_pid)
    :sys.replace_state(parent_pid, &swap_to_mock/1, 1_000)

    # Parent cleanup: register the same DOWN-blocking
    # teardown that `AgentTestHelpers.start_agent/1` uses.
    # Tests that already call `Supervisor.stop_agent/2`
    # mid-test terminate the parent early; the registered
    # cleanup is idempotent (the monitor's
    # `Registry.lookup/2` returns `:not_found` for an
    # already-dead pid and `wait_for_pid_down/2`
    # short-circuits).
    AgentTestHelpers.ensure_cleanup(name)

    {:ok, name, parent_pid, row.id}
  end

  defp swap_to_mock(state) do
    %{state | client_config: %{state.client_config | client: Nest.LLM.MockClient}}
  end

  # Read the runtime state of a started parent by introspecting
  # the GenServer + loading the persisted attrs. We need name
  # + chat_state.messages + next_message_index + parent_id +
  # depth + parent_name + the full Vocation struct to feed
  # back into `Supervisor.start_agent_with_parent/2`.
  defp read_parent_state(name, pid) do
    {:ok, attrs} = Persistence.build_attrs_for_start(AgentTestHelpers.current_space_id(), name)
    info = Nest.Agents.Agent.get_public_info(pid)
    msgs = Nest.Agents.Agent.get_messages(pid)

    %Nest.Agents.Agent{
      space_id: attrs.space_id,
      name: info.name,
      model: info.model,
      vocation: attrs.vocation,
      vocation_id: info.vocation_id,
      mounts:
        Mounts.new(
          attrs.workspace_path,
          nil,
          attrs.sandbox_backend,
          attrs.space_id,
          attrs.network_access
        ),
      llm_metrics: %Nest.Agents.Agent.LlmMetrics{
        context_limit: info.context_limit,
        context_limit_source: info.context_limit_source,
        usage_totals: info.usage,
        descendant_usage: info.descendant_usage
      },
      depth: info.depth,
      tree_position: %Nest.Agents.Agent.TreePosition{
        parent_id: info.parent_id,
        parent_name: info.parent_name
      },
      chat_state: %Nest.Agents.Agent.ChatState{
        messages: msgs,
        next_message_index: attrs.next_message_index,
        last_compaction_index: attrs.last_compaction_index
      }
    }
  end

  defp via_registry(name) do
    {:ok, pid} = AgentsRegistry.lookup(AgentTestHelpers.current_space_id(), name)
    pid
  end

  defp agent_count(space_id) do
    Nest.Repo.one(from(a in "agents", where: a.space_id == ^space_id, select: count(a.id)))
  end

  # `ExUnit`'s on_exit handler runs in a separate pid that does
  # NOT own the test pid's sandbox checkout, so a DB write
  # here would fail with `DBConnection.OwnershipError`.
  # `Supervisor.stop_agent/2` terminates the GenServer only;
  # the DB row is cleaned up by `DataCase`'s sandbox rollback
  # at test exit. The single-message `:DOWN` wait is the cleanup
  # bound (`AgentTestLifecycle.cleanup_ms/0`), not the tight detector
  # `wait_for_pid_down/2` defaults to: this is cleanup, so it must not
  # fail a passing test because a dying agent was a moment slow.
  defp safe_stop(space_id, name) do
    _ = Supervisor.stop_agent(space_id, name)
    AgentTestHelpers.wait_for_pid_down(space_id, name, AgentTestLifecycle.cleanup_ms())
  end
end
