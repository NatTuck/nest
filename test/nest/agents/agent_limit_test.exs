defmodule Nest.Agents.AgentLimitTest do
  @moduledoc """
  The per-space cap on **non-archived** agents (#225): a space's `max_agents`
  snapshot, or `Nest.Agents.StartGuard.default_max_agents/0` for a missing space.
  The cap gates **spawning only** (`Nest.Agents.StartGuard.within_agent_limit/2`,
  run by `Supervisor.start_pre_spawned/3`); a rehydrate or restart is exempt, so
  these tests drive the real create, spawn, rehydrate and restart routes rather
  than the guard in isolation.

  What is pinned here:

    * the default cap is enforced, and it counts *rows* — an agent with no live
      process (idle/offline) is still on the team;
    * a blueprint's cap, snapshotted onto the space at creation, moves the limit
      in both directions (below and above the default), and the refusal names the
      cap that was actually read;
    * archived agents do not count, so archiving one frees a slot;
    * a refused spawn leaves no orphan row and no process;
    * the guard's own contract at the cap — the race-safe last step: a start
      whose row puts the space over the cap is terminated synchronously through
      the supervisor, mirroring `Nest.Agents.StartGuardTest`'s archive arm.

  The tier *values* (Grading 20, Coding Team 10) are seed data and are pinned
  where the blueprint is read (`Nest.Blueprints.MaxAgentsTest`), not by spawning
  twenty agents here: the gate's `count > limit` does not depend on the number.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  alias Nest.Agents
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Registry
  alias Nest.Agents.StartGuard
  alias Nest.Agents.Supervisor
  alias Nest.Blueprints
  alias Nest.Persistence
  alias Nest.Spaces
  alias Nest.Vocations

  @model %{name: "qwen3.5-plus", provider: "model-studio"}

  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()
    {:ok, space_id: space_id, vocation_id: AgentTestHelpers.vocation_id_for_test()}
  end

  defp create_agent(space_id, vocation_id, name) do
    Agents.create_agent(space_id, @model, name: name, vocation_id: vocation_id)
  end

  defp create_agent!(space_id, vocation_id, name) do
    {:ok, ^name} = create_agent(space_id, vocation_id, name)
    name
  end

  defp fresh_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # A row with no process: an idle/offline agent. The cap counts rows, so this
  # occupies a slot exactly as a running agent does.
  defp insert_offline_row(space_id, vocation_id, name) do
    {:ok, _row} =
      Persistence.insert_agent(%{
        space_id: space_id,
        name: name,
        model: @model,
        vocation_id: vocation_id
      })

    name
  end

  defp space_with_cap(cap) do
    {:ok, blueprint} =
      Blueprints.create_blueprint(%{
        name: "cap-#{System.unique_integer([:positive])}",
        root_vocation: AgentTestHelpers.vocation_slug_for_test(),
        max_agents: cap
      })

    {:ok, space} =
      Spaces.create_space(nil, %{
        name: "cap-space-#{System.unique_integer([:positive])}",
        slug: "cap-space-#{System.unique_integer([:positive])}",
        blueprint_id: blueprint.id,
        workspace_path: AgentTestHelpers.default_test_workspace()
      })

    space.id
  end

  describe "the default cap" do
    test "counts idle rows, refuses the next create naming the limit, and rolls the row back",
         %{space_id: space_id, vocation_id: vocation_id} do
      limit = StartGuard.default_max_agents()
      assert limit == 5

      # Four running agents plus one offline row: five non-archived rows, only
      # four live processes. The offline one must occupy a slot — counting pids
      # would let the next create through.
      for _ <- 1..(limit - 1), do: create_agent!(space_id, vocation_id, fresh_name("run"))
      offline = insert_offline_row(space_id, vocation_id, fresh_name("offline"))
      assert Persistence.count_active_agents(space_id) == limit
      assert Registry.lookup(space_id, offline) == {:error, :not_found}

      too_many = fresh_name("too-many")

      log =
        capture_log(fn ->
          assert {:error, {:agent_limit, ^limit}} = create_agent(space_id, vocation_id, too_many)
        end)

      # The refusal is a failed start, so the pre-spawned row is rolled back and
      # logged — the same shape as any other start failure.
      assert log =~ "removing the row it pre-spawned"
      assert Persistence.fetch_agent(space_id, too_many) == {:error, :not_found}
      assert Registry.lookup(space_id, too_many) == {:error, :not_found}
      assert Persistence.count_active_agents(space_id) == limit
    end
  end

  describe "a blueprint's cap, snapshotted at creation" do
    test "lowers the cap below the default and refuses at it", %{vocation_id: vocation_id} do
      space_id = space_with_cap(2)

      create_agent!(space_id, vocation_id, fresh_name("a"))
      create_agent!(space_id, vocation_id, fresh_name("b"))

      log =
        capture_log(fn ->
          assert {:error, {:agent_limit, 2}} =
                   create_agent(space_id, vocation_id, fresh_name("c"))
        end)

      assert log =~ "removing the row it pre-spawned"
      assert Persistence.count_active_agents(space_id) == 2
    end

    test "raises the cap above the default and refuses at it", %{vocation_id: vocation_id} do
      # The Grading/Coding-Team direction: a cap larger than the default lets a
      # space grow past it. Six is enough to prove the gate reads the blueprint's
      # number rather than the default; the tier values themselves are pinned in
      # `Nest.Blueprints.MaxAgentsTest`.
      space_id = space_with_cap(6)

      for _ <- 1..6, do: create_agent!(space_id, vocation_id, fresh_name("member"))

      log =
        capture_log(fn ->
          assert {:error, {:agent_limit, 6}} =
                   create_agent(space_id, vocation_id, fresh_name("x"))
        end)

      assert log =~ "removing the row it pre-spawned"
      assert Persistence.count_active_agents(space_id) == 6
    end
  end

  describe "archived agents" do
    test "do not count, so archiving one frees a slot", %{
      space_id: space_id,
      vocation_id: vocation_id
    } do
      limit = StartGuard.default_max_agents()
      names = for _ <- 1..limit, do: create_agent!(space_id, vocation_id, fresh_name("m"))

      # At the cap: the next create is refused, and its pre-spawned row is
      # rolled back (the same logged shape as any other failed start).
      log =
        capture_log(fn ->
          assert {:error, {:agent_limit, ^limit}} =
                   create_agent(space_id, vocation_id, fresh_name("x"))
        end)

      assert log =~ "removing the row it pre-spawned"

      # Archive one (stops it and marks the row). The slot frees.
      assert :ok = Supervisor.archive_agent(space_id, hd(names))
      assert Persistence.count_active_agents(space_id) == limit - 1

      create_agent!(space_id, vocation_id, fresh_name("replacement"))
      assert Persistence.count_active_agents(space_id) == limit
    end
  end

  describe "the guard's last-step contract at the cap" do
    test "terminates a start over the cap synchronously and names the limit", %{
      space_id: space_id,
      vocation_id: vocation_id
    } do
      limit = StartGuard.default_max_agents()
      names = for _ <- 1..limit, do: create_agent!(space_id, vocation_id, fresh_name("m"))

      # At the cap a rehydrate of an existing agent adds no row and passes the
      # archive check, and a result that is not a start keeps its own reason.
      assert StartGuard.verify({:ok, hd(names)}, space_id, hd(names)) == {:ok, hd(names)}
      assert StartGuard.verify({:error, :not_found}, space_id, "anyone") == {:error, :not_found}

      # One more agent, started through the test-only route that skips the
      # guard — the reachable way to hold a live process over the cap, exactly
      # as a concurrent create's row can land before another start's count.
      extra = fresh_name("extra")

      attrs =
        %{
          name: extra,
          space_id: space_id,
          model: @model,
          vocation_id: vocation_id,
          vocation: Vocations.get_vocation(vocation_id),
          depth: 0
        }
        |> Persistence.build_agent_attrs()

      {:ok, _row} = Persistence.insert_agent(attrs)
      {:ok, pid} = Supervisor.start_under_test(attrs)
      ref = Process.monitor(pid)
      assert Persistence.count_active_agents(space_id) == limit + 1

      # The cap refuses and stops the process through the supervisor, so the
      # name is free when it returns — the refusal is true, not a promise. The
      # termination is synchronous, so the `:DOWN` is already in the mailbox:
      # `assert_received` (no timeout) is the assertion that proves it. The cap
      # is `within_agent_limit/2` (spawning only), not the archive `verify/3`.
      assert StartGuard.within_agent_limit(space_id, extra) == {:error, {:agent_limit, limit}}
      assert_received {:DOWN, ^ref, :process, ^pid, _reason}
      assert Registry.lookup(space_id, extra) == {:error, :not_found}
    end
  end

  describe "rehydrate and restart are exempt from the cap" do
    test "an over-cap space still loads and restarts its own agents, but cannot spawn", %{
      vocation_id: vocation_id
    } do
      space_id = space_with_cap(2)
      a = create_agent!(space_id, vocation_id, fresh_name("a"))
      b = create_agent!(space_id, vocation_id, fresh_name("b"))

      # Hold the space over its cap with a row + process started through the
      # test-only route that skips the gate — exactly the state a space created
      # before the cap existed (or whose cap was lowered) is in.
      extra = fresh_name("extra")

      attrs =
        %{
          name: extra,
          space_id: space_id,
          model: @model,
          vocation_id: vocation_id,
          vocation: Vocations.get_vocation(vocation_id),
          depth: 0
        }
        |> Persistence.build_agent_attrs()

      {:ok, _row} = Persistence.insert_agent(attrs)
      {:ok, _pid} = Supervisor.start_under_test(attrs)
      assert Persistence.count_active_agents(space_id) == 3

      # A stopped agent rehydrates despite the space being over cap: the load
      # path adds no row and must not be refused, or the space jams.
      :ok = Supervisor.stop_agent(space_id, a)
      assert {:ok, ^a} = Supervisor.fetch_or_start_agent(space_id, %{name: a})

      # A restart is exempt for the same reason.
      assert {:ok, ^b} = Supervisor.restart_agent(space_id, b)

      # A NEW spawn is still refused and rolled back — the cap gates spawning.
      log =
        capture_log(fn ->
          assert {:error, {:agent_limit, 2}} =
                   create_agent(space_id, vocation_id, fresh_name("new"))
        end)

      assert log =~ "removing the row it pre-spawned"
      assert Persistence.count_active_agents(space_id) == 3
    end

    test "a fresh spawn into a space at its cap is refused and rolled back", %{
      vocation_id: vocation_id
    } do
      # The create route is not the only spawn path: `spawn_agent_in_space/5`
      # (the `agents-spawn` tool) composes `verify` inside the start closure with
      # the cap in the `start_pre_spawned` wrapper. Drive it at the cap so that
      # composition is pinned, not just `create_agent/3`.
      space_id = space_with_cap(2)
      a = create_agent!(space_id, vocation_id, fresh_name("a"))
      _b = create_agent!(space_id, vocation_id, fresh_name("b"))
      assert Persistence.count_active_agents(space_id) == 2

      {:ok, pid} = Supervisor.get_agent(space_id, a)
      # allowlist: harness — the spawn path's parent-state argument
      parent_state = :sys.get_state(pid, 1_000)
      name = fresh_name("child")

      log =
        capture_log(fn ->
          assert {:error, {:agent_limit, 2}} =
                   Supervisor.spawn_agent_in_space(
                     parent_state,
                     name,
                     AgentTestHelpers.vocation_slug_for_test()
                   )
        end)

      assert log =~ "removing the row it pre-spawned"
      assert Persistence.fetch_agent(space_id, name) == {:error, :not_found}
      assert Registry.lookup(space_id, name) == {:error, :not_found}
      assert Persistence.count_active_agents(space_id) == 2
    end
  end
end
