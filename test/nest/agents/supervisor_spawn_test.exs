defmodule Nest.Agents.SupervisorSpawnTest do
  @moduledoc """
  Tests for `Supervisor.spawn_agent_in_space/3` — the entry
  point that creates a fresh-context sub-agent in a space,
  authorized against the space's blueprint
  `spawnable_vocations` whitelist.

  `spawn_agent_in_space/3` requires a real parent agent (it
  reads `name`, `depth`, and resolves the parent's DB row for
  `parent_id`), so each test starts a real coordinator agent
  in the target space and passes its runtime state.

  ## What's covered

    * Unrestricted space (no blueprint) → any vocation spawns.
    * Whitelisted blueprint → allowed vocation spawns, denied
      vocation returns `{:error, {:vocation_not_spawnable, _}}`.
    * Omitted `vocation` → the space's blueprint
      `default_spawnable_vocation` (held to the whitelist like an
      explicit slug), or a `{:vocation_required, _}` refusal naming
      the argument when the blueprint names no default. Never the
      caller's own vocation.
    * Duplicate name → `{:error, :duplicate_name}` (the
      `(space_id, name)` composite unique index).
    * Fresh context → the spawned agent's message count is 1
      (system prompt only).
    * Fresh spawns get `depth = parent + 1`.
  """
  use Nest.DataCase, async: true

  import ExUnit.CaptureLog

  import Nest.Test.TmpCleanup

  alias Nest.Agents
  alias Nest.Agents.Agent.BatchPlan
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Blueprints
  alias Nest.Spaces
  alias Nest.Vocations

  setup do
    {:ok, space_id} = AgentTestHelpers.create_test_space()
    {:ok, space_id: space_id}
  end

  # Start a real coordinator agent in `space_id` and return
  # its runtime state. `spawn_agent_in_space/3` needs a real
  # parent (name + persisted row for `parent_id`).
  defp coordinator_state(space_id) do
    name = "coord-#{System.unique_integer([:positive])}"

    {:ok, ^name} =
      Agents.create_agent(space_id, test_model(),
        name: name,
        vocation_id: AgentTestHelpers.vocation_id_for_test(),
        # Every agent needs a workspace, and a spawned child inherits its
        # parent's. Without one the coordinator could not spawn.
        workspace_path: AgentTestHelpers.default_test_workspace()
      )

    AgentTestHelpers.ensure_cleanup(name)

    {:ok, pid} = Supervisor.get_agent(space_id, name)
    # allowlist: harness — spawn_agent_in_space/3's state argument
    :sys.get_state(pid, 1_000)
  end

  defp test_model, do: %{name: "qwen3.5-plus", provider: "model-studio"}

  # A parent started straight from attrs, in a space whose workspace
  # `Nest.Sandbox.workspace_error/1` refuses. `Agents.create_agent/3` runs that
  # gate itself, so this is the only way to reach the spawn path's workspace
  # refusals with a running parent behind them.
  defp start_parent_in(space_id, workspace) do
    name = "coord-#{System.unique_integer([:positive])}"
    vocation_id = AgentTestHelpers.vocation_id_for_test()

    attrs =
      %{
        name: name,
        space_id: space_id,
        model: test_model(),
        vocation_id: vocation_id,
        vocation: Vocations.get_vocation(vocation_id),
        depth: 0,
        sandbox_backend: "bwrap",
        network_access: true,
        workspace_path: workspace
      }
      |> Nest.Persistence.build_agent_attrs()

    {:ok, _row} = Nest.Persistence.insert_agent(attrs)
    {:ok, pid} = Supervisor.start_under_test(attrs)
    AgentTestHelpers.ensure_cleanup(name)
    # allowlist: harness — spawn_agent_in_space/3's state argument
    :sys.get_state(pid, 1_000)
  end

  defp agent_count(space_id) do
    Nest.Repo.one(from(a in "agents", where: a.space_id == ^space_id, select: count(a.id)))
  end

  defp message_count(space_id) do
    Nest.Repo.one(
      from(m in "messages",
        join: a in "agents",
        on: m.agent_id == a.id,
        where: a.space_id == ^space_id,
        select: count(m.id)
      )
    )
  end

  # Insert an agent row and archive it, returning the row. `parent_id`
  # and `depth` are what set the subtree shape: once the processes are
  # archived the `ChildRegistry` entries are gone, so the persisted
  # `parent_id` links are the only record of the tree.
  defp insert_archived_row(space_id, name, parent_id \\ nil, depth \\ 0) do
    {:ok, row} =
      Nest.Persistence.insert_agent(%{
        space_id: space_id,
        name: name,
        model: test_model(),
        vocation_id: AgentTestHelpers.vocation_id_for_test(),
        parent_id: parent_id,
        depth: depth
      })

    assert :ok = Nest.Persistence.archive_agent(space_id, name)
    row
  end

  # Collect `count` `agent:unarchived` broadcasts for `space_id`, in the
  # order they arrived.
  defp unarchived_names(space_id, count) do
    for _ <- 1..count do
      assert_receive %Phoenix.Socket.Broadcast{
                       event: "agent:unarchived",
                       payload: %{"space_id" => ^space_id, "name" => name}
                     },
                     1_000

      name
    end
  end

  defp fresh_vocation do
    {:ok, vocation} =
      Vocations.upsert_vocation(%{
        name: "SpawnVocation-#{System.unique_integer([:positive])}",
        description: "Spawn test",
        system_prompt: "You are a specialist.",
        tools: ["context"]
      })

    vocation
  end

  # A space whose blueprint names `blueprint_attrs` (`name` is made unique
  # here). These spaces are created with `Spaces.create_space/2` directly rather
  # than through `create_space_with_root_agent/2`, so every one of them needs a
  # workspace from stage 4 on.
  defp space_with_blueprint(prefix, blueprint_attrs) do
    {:ok, blueprint} =
      Blueprints.create_blueprint(
        Map.merge(%{name: "#{prefix}-#{System.unique_integer([:positive])}"}, blueprint_attrs)
      )

    {:ok, space} =
      Spaces.create_space(nil, %{
        name: "#{prefix}-space-#{System.unique_integer([:positive])}",
        slug: "#{prefix}-space-#{System.unique_integer([:positive])}",
        blueprint_id: blueprint.id,
        workspace_path: AgentTestHelpers.default_test_workspace()
      })

    space
  end

  describe "spawn_agent_in_space/3 in an unrestricted space" do
    test "spawns an independent specialist with any vocation", %{space_id: space_id} do
      vocation = fresh_vocation()
      name = "specialist-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      assert {:ok, info} = Agents.get_info(space_id, name)
      assert info.vocation_id == vocation.id

      # Fresh context: the child's own system prompt and nothing inherited
      # from the parent (inheriting is the clone path's fork).
      assert info.message_count == 1
      assert info.depth == state.depth + 1
      # No override was named, so the child runs on the parent's model.
      assert info.model == state.model
    end

    test "fresh spawn at max depth has agents-spawn excluded from its tool list",
         %{space_id: space_id} do
      max = Config.configured_max_depth()
      vocation = fresh_vocation()
      name = "maxdepth-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)
      state = %{state | depth: max}

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      {:ok, pid} = Supervisor.get_agent(space_id, name)
      # allowlist: snapshot — depth + tools
      child_state = :sys.get_state(pid, 1_000)
      assert child_state.depth == max + 1
      refute Enum.any?(child_state.tools, &(&1.name == "agents-spawn"))
    end

    test "rejects a duplicate name in the space", %{space_id: space_id} do
      vocation = fresh_vocation()
      name = "dup-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      assert {:error, :duplicate_name} =
               Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)
    end

    test "an unknown vocation slug is rejected", %{space_id: space_id} do
      name = "unknown-voc-#{System.unique_integer([:positive])}"
      state = coordinator_state(space_id)

      assert {:error, {:vocation_not_found, "does-not-exist"}} =
               Supervisor.spawn_agent_in_space(state, name, "does-not-exist")
    end
  end

  describe "spawn_agent_in_space/3 whitelist enforcement" do
    test "allows a whitelisted vocation and denies a non-whitelisted one" do
      allowed = fresh_vocation()
      denied = fresh_vocation()

      space =
        space_with_blueprint("whitelist", %{
          root_vocation: allowed.slug,
          spawnable_vocations: [allowed.slug]
        })

      state = coordinator_state(space.id)
      allowed_name = "allowed-#{System.unique_integer([:positive])}"
      denied_name = "denied-#{System.unique_integer([:positive])}"

      assert {:ok, ^allowed_name} =
               Supervisor.spawn_agent_in_space(state, allowed_name, allowed.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, allowed_name) end)

      # The refusal carries the whitelisted vocations as {name, slug}
      # labels so the caller can tell the model what it may spawn.
      assert {:error, {:vocation_not_spawnable, [{_name, allowed_slug}]}} =
               Supervisor.spawn_agent_in_space(state, denied_name, denied.slug)

      assert allowed_slug == allowed.slug
      refute Enum.member?(Agents.list_agents_for_space(space.id), denied_name)
    end

    test "omitting vocation takes the blueprint's default_spawnable_vocation" do
      allowed = fresh_vocation()

      space =
        space_with_blueprint("auto-wl", %{
          root_vocation: allowed.slug,
          spawnable_vocations: [allowed.slug],
          default_spawnable_vocation: allowed.slug
        })

      # The coordinator's own vocation (Test Default) is neither the blueprint's
      # default nor whitelisted — exactly the "Head TA may only spawn Graders"
      # shape, and the point of the column: the model does not have to know the
      # slug, and the caller's own vocation is not the answer.
      state = coordinator_state(space.id)
      refute state.vocation_id == allowed.id

      name = "auto-#{System.unique_integer([:positive])}"

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, name) end)

      {:ok, pid} = Supervisor.get_agent(space.id, name)
      assert Nest.Agents.Agent.get_public_info(pid, 1_000).vocation_id == allowed.id
    end

    test "omitting vocation is refused when the blueprint names no default" do
      allowed_a = fresh_vocation()
      allowed_b = fresh_vocation()

      space =
        space_with_blueprint("nodefault-wl", %{
          root_vocation: allowed_a.slug,
          spawnable_vocations: [allowed_a.slug, allowed_b.slug]
        })

      state = coordinator_state(space.id)
      name = "nodefault-#{System.unique_integer([:positive])}"

      # Refused, not guessed. Neither the caller's own vocation nor the first of
      # the allowed list is the answer to "which vocation?" — the refusal names
      # the argument to supply and carries the vocations that would be accepted,
      # so the model can retry in one step.
      assert {:error, {:vocation_required, labels}} =
               Supervisor.spawn_agent_in_space(state, name)

      slugs = Enum.map(labels, &elem(&1, 1))
      assert Enum.sort(slugs) == Enum.sort([allowed_a.slug, allowed_b.slug])
      refute Enum.member?(Agents.list_agents_for_space(space.id), name)

      # The tuple is what the tool layer sees; the *model* sees the rendered text,
      # so that is what has to name the argument. (The `agents-spawn` renderer is
      # private to `ToolLoop`; this is the batch one, and both are fed the same
      # tuple.)
      message = BatchPlan.spawn_error_message({:vocation_required, labels})
      assert message =~ "`vocation` is required"
      assert message =~ allowed_a.slug
    end

    test "an omitted vocation is refused in a space with no blueprint at all", %{
      space_id: space_id
    } do
      # The setup's space has no blueprint (`create_test_space/0`), so there is
      # nothing to take a default from and the spawn is refused rather than
      # guessing the caller's own vocation. This is the shape that broke
      # `AgentsBatchTest`: its space is blueprint-less and its batch names no
      # vocation, so no child was ever spawned and the test died on the
      # `agent_created` broadcast that stopped arriving.
      state = coordinator_state(space_id)
      name = "noblueprint-#{System.unique_integer([:positive])}"

      assert {:error, {:vocation_required, []}} =
               Supervisor.spawn_agent_in_space(state, name)

      refute Enum.member?(Agents.list_agents_for_space(space_id), name)

      # An empty allowed list means the space is *unrestricted* — no whitelist,
      # so anything goes — not that nothing is allowed. The text the model reads
      # has to say which, or the retry is a guess.
      message = BatchPlan.spawn_error_message({:vocation_required, []})
      assert message =~ "`vocation` is required"
      assert message =~ "any vocation is allowed"
      refute message =~ "allowed: "
    end

    test "an empty spawnable_vocations list is unrestricted" do
      vocation = fresh_vocation()

      space =
        space_with_blueprint("empty-wl", %{
          root_vocation: vocation.slug,
          spawnable_vocations: []
        })

      name = "any-#{System.unique_integer([:positive])}"
      state = coordinator_state(space.id)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)

      on_exit(fn -> _ = Supervisor.stop_agent(space.id, name) end)
    end
  end

  describe "a failed spawn" do
    test "leaves no orphan row, so the same name can be spawned again", %{space_id: space_id} do
      # An explicit vocation, because a space with no blueprint now has no
      # `default_spawnable_vocation` and refuses an omitted one outright — see
      # the whitelist describe above. This test is about the rollback, so it says
      # which specialist it is spawning and gets on with it.
      vocation = fresh_vocation()
      state = coordinator_state(space_id)
      name = "spawn-rollback-#{System.unique_integer([:positive])}"
      space_dir = TmpSpace.space_dir(space_id, "bwrap")

      # Make the spawn fail deterministically: a *file* where the child's own
      # scratch directory belongs, so `TmpSpace.create/3`'s `File.mkdir_p!`
      # refuses it. That happens in the child's `init/1` — composing its prompt
      # no longer creates the directory (the `AGENTS.md` read is a host read;
      # issue #132), so the spawn now fails *after* `pre_spawn` wrote the row,
      # and the rollback is what the assertion below is about.
      File.mkdir_p!(space_dir)
      blocker = Path.join(space_dir, name)
      File.write!(blocker, "not a directory")

      on_exit(fn -> File.rm(blocker) end)

      # `DynamicSupervisor.start_child/2` turns a raise out of `init/1` into
      # `{:error, {exception, stacktrace}}`; `start_pre_spawned/3` rolls the row
      # back, logs that it did, and returns the error. Asserted inside the
      # capture: `Logger.warning` is synchronous, so the line is guaranteed to
      # have been emitted by the time the call returns.
      log =
        capture_log(fn ->
          assert {:error, {%File.Error{}, _stacktrace}} =
                   Supervisor.spawn_agent_in_space(state, name, vocation.slug)
        end)

      assert log =~ "removing the row it pre-spawned"

      # The row the spawn pre-spawned is gone, so the name is free again rather
      # than blocked by an orphan — and its system message went with it: the one
      # left is the coordinator's.
      assert Nest.Persistence.fetch_agent(space_id, name) == {:error, :not_found}
      assert message_count(space_id) == 1

      File.rm!(blocker)

      assert {:ok, ^name} = Supervisor.spawn_agent_in_space(state, name, vocation.slug)
      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      # Exactly one row was added: the failed attempt left nothing behind.
      assert agent_count(space_id) == 2
    end
  end

  describe "unarchive_agent/2" do
    test "returns not_found for a missing agent", %{space_id: space_id} do
      name = "ghost-#{System.unique_integer([:positive])}"

      assert {:error, :not_found} = Supervisor.unarchive_agent(space_id, name)
    end

    test "restores a parent together with its archived children", %{space_id: space_id} do
      suffix = System.unique_integer([:positive])
      parent = "subtree-parent-#{suffix}"
      child_a = "subtree-child-a-#{suffix}"
      child_b = "subtree-child-b-#{suffix}"

      parent_row = insert_archived_row(space_id, parent)
      _child_a_row = insert_archived_row(space_id, child_a, parent_row.id, 1)
      _child_b_row = insert_archived_row(space_id, child_b, parent_row.id, 1)

      Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

      assert :ok = Supervisor.unarchive_agent(space_id, parent)

      # One broadcast per restored row, in name order (the subtree walk
      # is sorted, not map-ordered), and none for anything outside it.
      assert unarchived_names(space_id, 3) ==
               Enum.sort([parent, child_a, child_b])

      for name <- [parent, child_a, child_b] do
        assert {:ok, %{archived: false}} = Nest.Persistence.fetch_agent(space_id, name)
      end
    end

    test "is a no-op for an agent that is already active", %{space_id: space_id} do
      name = "already-active-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Nest.Persistence.insert_agent(%{
          space_id: space_id,
          name: name,
          model: test_model(),
          vocation_id: AgentTestHelpers.vocation_id_for_test()
        })

      Phoenix.PubSub.subscribe(Nest.PubSub, "lobby")

      assert :ok = Supervisor.unarchive_agent(space_id, name)

      # Nothing changed, so nothing is broadcast: the restore is
      # synchronous, so a broadcast would already be in the mailbox.
      refute_received %Phoenix.Socket.Broadcast{
        event: "agent:unarchived",
        payload: %{"space_id" => ^space_id, "name" => ^name}
      }

      assert {:ok, %{archived: false}} = Nest.Persistence.fetch_agent(space_id, name)
    end
  end

  describe "spawn workspace validation" do
    # The child's workspace is the **space's** (`spaces.workspace_path`), which is
    # what `Persistence.build_agent_attrs/1` puts on its attrs. This used to read
    # the parent's *cached* mounts instead and refuse with `:workspace_required` —
    # a reason for a state a space cannot be in (both space changesets
    # `validate_required/2` a workspace). That is what made a context clone, whose
    # own mounts had no workspace, unable to spawn anything at all.
    test "a parent whose mounts lost the workspace can still spawn", %{space_id: space_id} do
      state = coordinator_state(space_id)
      name = "ws-child-#{System.unique_integer([:positive])}"
      workspace = Spaces.environment(space_id).workspace_path

      assert {:ok, ^name} =
               Supervisor.spawn_agent_in_space(
                 %{state | mounts: %{state.mounts | workspace: nil}},
                 name,
                 fresh_vocation().slug
               )

      on_exit(fn -> _ = Supervisor.stop_agent(space_id, name) end)

      # And the child really carries it: this is the value its tools resolve
      # against and its prompt states.
      assert {:ok, %{workspace_path: ^workspace}} = Agents.get_info(space_id, name)
    end

    test "refuses a space whose workspace directory is gone", %{space_id: space_id} do
      state = coordinator_state(space_id)
      workspace = Spaces.environment(space_id).workspace_path
      name = "ws-child-#{System.unique_integer([:positive])}"

      # A workspace deleted out from under a running space is the reachable way
      # to be refused here; the identifying string is the `rm_rf!` guard.
      assert workspace =~ "agent-ws-"
      File.rm_rf!(workspace)

      assert {:error, :workspace_missing} =
               Supervisor.spawn_agent_in_space(state, name, fresh_vocation().slug)

      # Nothing was inserted: the refusal is before the row write.
      assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, name)
    end

    test "refuses a space whose workspace is under /tmp", %{} do
      workspace =
        Path.join(System.tmp_dir!(), "nest-spawn-ws-#{System.unique_integer([:positive])}")

      File.mkdir_p!(workspace)
      on_exit(fn -> rm_tmp!(workspace, "nest-spawn-ws-") end)
      {:ok, space_id} = AgentTestHelpers.create_test_space(%{workspace_path: workspace})

      # The lobby's create path refuses a /tmp workspace before the row is
      # written (`Nest.Spaces.Creation.ensure_root_workspace/1`), so a space like
      # this can only be a legacy row or a context caller's — and the spawn path
      # still has to answer with a sentence rather than an atom.
      state = start_parent_in(space_id, workspace)
      name = "ws-child-#{System.unique_integer([:positive])}"

      assert {:error, :workspace_under_tmp} =
               Supervisor.spawn_agent_in_space(state, name, fresh_vocation().slug)

      assert {:error, :not_found} = Nest.Persistence.fetch_agent(space_id, name)
    end
  end
end
