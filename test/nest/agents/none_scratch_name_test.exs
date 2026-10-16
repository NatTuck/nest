defmodule Nest.Agents.NoneScratchNameTest do
  @moduledoc """
  The one name rule that is about a *directory*: a `"none"` space's agent
  scratch dir is `/tmp/<name>` in the host's single `/tmp`, so two `"none"`
  spaces share one namespace of agent names.

  Both halves are pinned here — the creation boundary that refuses a collision,
  and the generator that must never propose one — plus the two things that must
  *not* happen: a bwrap space being constrained by it, and a fresh agent
  inheriting a stopped one's scratch.
  """

  use Nest.DataCase, async: true

  alias Nest.Agents
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.Supervisor
  alias Nest.Persistence
  alias Nest.Sandbox.Mounts
  alias Nest.Spaces
  alias Nest.Test.TmpCleanup

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Start a live agent in `space_id` under an explicit name, and register the
  # same teardown `AgentTestHelpers.start_agent/1` uses (the agent is not
  # linked to the test process).
  defp start_named(space_id, name, opts \\ []) do
    {:ok, ^name} =
      Agents.create_agent(
        space_id,
        %{name: "qwen3.5-plus", provider: "model-studio"},
        Keyword.merge(
          [name: name, vocation_id: AgentTestHelpers.vocation_id_for_test()],
          opts
        )
      )

    AgentTestHelpers.ensure_cleanup(name)
    name
  end

  # Start an agent from a row that already exists, the way
  # `Supervisor.fetch_or_start_agent/2` rehydrates one — no `pre_spawn`, so the
  # creation boundary does not run.
  defp start_rehydrated(space_id, name) do
    model = %{name: "qwen3.5-plus", provider: "model-studio"}
    vocation_id = AgentTestHelpers.vocation_id_for_test()

    {:ok, _row} =
      Persistence.insert_agent(%{
        space_id: space_id,
        name: name,
        model: model,
        vocation_id: vocation_id
      })

    {:ok, _pid} =
      Supervisor.start_under_test(%{
        space_id: space_id,
        name: name,
        model: model,
        vocation_id: vocation_id,
        vocation: Nest.Vocations.get_vocation(vocation_id),
        workspace_path: nil,
        sandbox_backend: "none",
        depth: 0
      })

    # `ensure_cleanup/1` names the space through `current_space_id/0`, so point it
    # at this one first: the test's own stops happen mid-body, and a failure
    # before them must not leave a live agent behind.
    AgentTestHelpers.put_space_id(space_id)
    AgentTestHelpers.ensure_cleanup(name)
    name
  end

  describe "the creation boundary" do
    test "a none-space agent may not take a live none-space agent's scratch name" do
      {:ok, space_a} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
      {:ok, space_b} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})

      name = unique("shared-name")
      start_named(space_a, name)

      assert {:error, {:scratch_name_in_use, other_name}} =
               Agents.create_agent(
                 space_b,
                 %{name: "qwen3.5-plus", provider: "model-studio"},
                 name: name,
                 vocation_id: AgentTestHelpers.vocation_id_for_test()
               )

      # The refusal names the *other* space, so a client can say which one.
      assert other_name == Nest.Spaces.get_space(space_a).name
    end

    test "a bwrap space is not constrained by a live none-space agent's name" do
      {:ok, none_space} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
      {:ok, bwrap_space} = AgentTestHelpers.create_test_space()

      name = unique("cross-backend")
      start_named(none_space, name)

      # The `none` side's scratch is the host's own `/tmp/<name>`, and its
      # `terminate/2` cleanup refuses while the bwrap space's live agent holds the
      # same name (the guard is registry-only, so it cannot tell that the other
      # agent's scratch is under a different root). Harmless in production — a
      # stale directory — but a test has to remove its own.
      none_scratch = TmpSpace.agent_dir(none_space, name, "none")
      on_exit(fn -> TmpCleanup.rm_tmp!(none_scratch, "cross-backend") end)

      # Different roots, so the same name is a different directory: no rule.
      assert start_named(bwrap_space, name) == name
      assert none_scratch == "/tmp/#{name}"
      refute TmpSpace.agent_dir(bwrap_space, name, "bwrap") == "/tmp/#{name}"
    end

    test "an unusable name is refused by the row changeset, not by a raise" do
      {:ok, space_id} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})

      # The gate derives a path from the name, so it must not be handed a name
      # that cannot be one — the row's own changeset is what refuses it, and a
      # custom client must still get that refusal rather than a crash.
      assert {:error, %Ecto.Changeset{} = changeset} =
               Agents.create_agent(
                 space_id,
                 %{name: "qwen3.5-plus", provider: "model-studio"},
                 name: "../escape",
                 vocation_id: AgentTestHelpers.vocation_id_for_test()
               )

      assert {"must contain only letters, digits, `_` and `-`", _meta} =
               changeset.errors[:name]
    end

    test "a name freed by a stopped agent is usable again" do
      {:ok, space_a} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
      {:ok, space_b} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})

      name = unique("recycled")
      start_named(space_a, name)

      # `stop_agent/2` fires the exit and returns before the process is gone,
      # so wait for the death itself: the registry entry (and the scratch dir)
      # are released from `terminate/2`, ahead of the DOWN.
      {:ok, pid} = Nest.Agents.Registry.lookup(space_a, name)
      ref = Process.monitor(pid)
      assert :ok = Supervisor.stop_agent(space_a, name)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert start_named(space_b, name) == name
    end
  end

  describe "a name another live agent holds" do
    test "stopping one of two live same-named agents leaves the shared scratch" do
      {:ok, space_a} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
      {:ok, space_b} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})

      name = unique("shared-live")
      start_named(space_b, name)

      # The second one can only be live through the *rehydration* path: the
      # creation boundary refuses a name a live agent in another `none` space
      # holds, but restarting a row on demand is deliberately not gated. That is
      # how two live agents end up sharing `/tmp/<name>`.
      start_rehydrated(space_a, name)

      scratch = TmpSpace.agent_dir(space_a, name, "none")
      assert scratch == TmpSpace.agent_dir(space_b, name, "none")
      File.write!(Path.join(scratch, "mine.txt"), "keep")

      {:ok, pid} = Nest.Agents.Registry.lookup(space_a, name)
      ref = Process.monitor(pid)
      assert :ok = Supervisor.stop_agent(space_a, name)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # Space B's agent is still live, so the directory is not ours to remove.
      assert File.dir?(scratch)
      assert File.read!(Path.join(scratch, "mine.txt")) == "keep"
    end
  end

  describe "a name nothing live holds" do
    test "an unmarked directory of that name is refused, never adopted" do
      {:ok, space_id} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})

      # A `none` agent's scratch is the host's own `/tmp/<name>`, and the name is
      # client- and model-controlled. This one is not Nest's — no marker — so
      # taking the name must not touch it, and must not *adopt* it either:
      # stamping the marker in would license the next `cleanup/3` to delete it.
      name = unique("nest-rmtest")
      dir = Path.join(System.tmp_dir!(), name)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "host-file"), "not Nest's")
      on_exit(fn -> TmpCleanup.rm_tmp!(dir, "nest-rmtest") end)

      assert {:error, {:scratch_path_taken, ^dir}} =
               Agents.create_agent(
                 space_id,
                 %{name: "qwen3.5-plus", provider: "model-studio"},
                 name: name,
                 vocation_id: AgentTestHelpers.vocation_id_for_test()
               )

      refute File.exists?(Path.join(dir, ".nest-scratch"))
      assert File.read!(Path.join(dir, "host-file")) == "not Nest's"
    end
  end

  describe "the mounts an agent's prompt is composed through" do
    test "carry the scratch bind for a bwrap space too" do
      # The regression guard for the docker defect: reverting the prompt's mounts
      # to a nil scratch fails nothing today, because a docker space *with a
      # workspace* cannot be created in the suite (its prompt read is a real
      # `docker exec`). What it does leave behind is observable under bwrap: the
      # prompt's `AGENTS.md` read stages its transcript through the scratch bind,
      # so `<space_dir>/.cmds` exists afterwards only if the mounts carried one.
      # (Under bwrap the read would have succeeded either way — bwrap reaches
      # `<host tmp>/.nest-cmds` through its read-only root bind — which is exactly
      # why the staging directory, not the content, is the observable. Building
      # the agent's *tools* with a mounts value stages nothing (checked directly:
      # `Tools.get_functions/2` creates no `.cmds`), so the directory can only
      # come from the prompt's read — though not from *which* of the two prompt
      # call sites.)
      workspace = Path.join([File.cwd!(), "_build", "tmp", "nest_prompt_mounts"])
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "AGENTS.md"), "# Project notes\n")

      on_exit(fn ->
        if String.contains?(workspace, "nest_prompt_mounts"), do: File.rm_rf(workspace)
      end)

      {:ok, space_id} = AgentTestHelpers.create_test_space()

      name = start_named(space_id, unique("bwrap-mounts"), workspace_path: workspace)

      {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)

      # allowlist: snapshot — the mounts the *start path* built, which is the
      # thing under test; no accessor exposes them and there is no event for
      # "the agent started with these mounts".
      mounts = Mounts.from_agent(:sys.get_state(pid))
      scratch = Mounts.scratch(mounts)

      assert scratch == TmpSpace.agent_dir(space_id, name, "bwrap")
      assert File.dir?(Path.join(Path.dirname(scratch), ".cmds"))
    end

    test "carry the agent's real scratch, so a command can be staged" do
      {:ok, space_id} = AgentTestHelpers.create_test_space(%{sandbox_backend: "docker"})

      # No workspace: composing the prompt then reads no `AGENTS.md`, so this
      # never runs the container. What it does assert is the thing that made a
      # docker space with a workspace silently lose that section — the mounts the
      # prompt is composed through must name the agent's scratch, or the staged
      # transcript lands where the container cannot reach it.
      name = start_named(space_id, unique("docker-mounts"))
      {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)

      # allowlist: snapshot — the mounts the *start path* built, which is the
      # thing under test; no accessor exposes them and there is no event for
      # "the agent started with these mounts" (the creation itself is the wait).
      mounts = Mounts.from_agent(:sys.get_state(pid))

      assert Mounts.scratch(mounts) == TmpSpace.agent_dir(space_id, name, "docker")
      assert Mounts.space_id(mounts) == space_id
      assert Mounts.backend(mounts) == "docker"
      assert File.dir?(Mounts.scratch(mounts))
    end
  end

  describe "the generator's input" do
    test "skips a name a live agent in another none space holds" do
      {:ok, space_a} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
      {:ok, space_b} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})

      name = unique("held-name")
      start_named(space_a, name)

      names = Supervisor.existing_names_for_space(space_b)

      assert MapSet.member?(names, name)
      refute Supervisor.generate_unique_name_for_space(space_b) == name
    end

    test "does not add another space's names to a bwrap space" do
      {:ok, none_space} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
      {:ok, bwrap_space} = AgentTestHelpers.create_test_space()

      name = unique("not-held")
      start_named(none_space, name)

      refute MapSet.member?(Supervisor.existing_names_for_space(bwrap_space), name)
    end
  end

  describe "a fresh agent's scratch" do
    test "a stale directory left by a stopped agent is cleared at creation" do
      {:ok, space_a} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
      {:ok, space_b} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})

      name = unique("stale")
      scratch = TmpSpace.create(space_a, name, "none")
      File.write!(Path.join(scratch, "leftover.txt"), "old")

      start_named(space_b, name)

      # The new agent owns the same path (that is the whole point of the name
      # rule) and must not inherit the previous owner's files.
      assert TmpSpace.agent_dir(space_b, name, "none") == scratch
      refute File.exists?(Path.join(scratch, "leftover.txt"))
    end

    test "a live agent's scratch is never cleared" do
      {:ok, space_a} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
      {:ok, space_b} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})

      name = unique("live-scratch")
      start_named(space_a, name)

      scratch = TmpSpace.agent_dir(space_a, name, "none")
      File.write!(Path.join(scratch, "mine.txt"), "keep")

      # The other space asking for the same name is refused, so the refusal is
      # what protects the live scratch — nothing else may delete it.
      assert {:error, {:scratch_name_in_use, _}} =
               Agents.create_agent(
                 space_b,
                 %{name: "qwen3.5-plus", provider: "model-studio"},
                 name: name,
                 vocation_id: AgentTestHelpers.vocation_id_for_test()
               )

      assert File.read!(Path.join(scratch, "mine.txt")) == "keep"
    end
  end

  describe "Spaces.sandbox_backend/1" do
    test "is what the boundary consults" do
      {:ok, none_space} = AgentTestHelpers.create_test_space(%{sandbox_backend: "none"})
      {:ok, bwrap_space} = AgentTestHelpers.create_test_space()

      assert Spaces.sandbox_backend(none_space) == "none"
      assert Spaces.sandbox_backend(bwrap_space) == "bwrap"
    end
  end
end
