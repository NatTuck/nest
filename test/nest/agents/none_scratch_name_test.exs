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
  alias Nest.Sandbox.{Mounts, Paths}
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
        network_access: false,
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
    # There was a "carry the scratch bind for a bwrap space too" test here. It
    # asserted that `<space_dir>/.cmds` existed after an agent started, which
    # could only happen if the prompt's `AGENTS.md` read staged a command — and
    # therefore that the mounts the prompt was composed through carried the
    # scratch bind. Its subject is gone, and so is the bug class it guarded: the
    # `AGENTS.md` read is a **host** read (issue #132), so composing a prompt
    # stages nothing on any backend, and a docker space can no longer silently
    # lose the section because its prompt read staged where the container could
    # not see it. What remains worth pinning is that the mounts name the right
    # scratch, which the next test does directly.
    test "the prompt's mounts and the agent's are the same value" do
      # `Init` builds the prompt's mounts with `TmpSpace.prompt_mounts/5` and the
      # agent's with `agent_mounts/6` — two independent constructions. Their
      # agreement is what makes "the prompt states the environment its tools will
      # use" true, and nothing else asserts it: the old `.cmds` guard observed it
      # indirectly, through the staging a sandboxed `AGENTS.md` read left behind.
      {:ok, space_id} = AgentTestHelpers.create_test_space()
      workspace = AgentTestHelpers.default_test_workspace()
      name = start_named(space_id, unique("mounts-agree"), workspace_path: workspace)

      {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)

      # allowlist: snapshot — the mounts the *start path* built, which is the
      # thing under test; no accessor exposes them and there is no event for
      # "the agent started with these mounts".
      agent_mounts = Mounts.from_agent(:sys.get_state(pid))

      assert agent_mounts ==
               TmpSpace.prompt_mounts(
                 workspace,
                 space_id,
                 name,
                 Mounts.backend(agent_mounts),
                 Mounts.network_access(agent_mounts)
               )
    end

    test "carry the agent's real scratch, so a command can be staged" do
      {:ok, space_id} = AgentTestHelpers.create_test_space(%{sandbox_backend: "docker"})

      # This agent's *mounts* name no workspace: a workspace reaches an agent
      # through `Agents.create_agent/3`'s `:workspace_path` option and from
      # nowhere else, and `start_named/3` names none. That no longer decides
      # whether the prompt makes a `docker exec` — the `AGENTS.md` read is a host
      # read, so no agent of any shape reaches a backend from composition — but
      # what this asserts is unaffected: the mounts the prompt is composed
      # through must name the agent's scratch, so the mounts are the agent's real
      # ones rather than a second spelling of them.
      name = start_named(space_id, unique("docker-mounts"))
      {:ok, pid} = Nest.Agents.Registry.lookup(space_id, name)

      # allowlist: snapshot — the mounts the *start path* built, which is the
      # thing under test; no accessor exposes them and there is no event for
      # "the agent started with these mounts" (the creation itself is the wait).
      mounts = Mounts.from_agent(:sys.get_state(pid))

      assert Mounts.scratch(mounts) == TmpSpace.agent_dir(space_id, name, "docker")
      assert Mounts.space_id(mounts) == space_id
      assert Mounts.backend(mounts) == "docker"

      # The scratch names a path *inside* the container — the container's own
      # `/tmp/<agent>` — so nothing on the host holds it, and the command that
      # runs is what makes it. What this pins is that the mounts the prompt is
      # composed through name that spelling rather than a host directory, which
      # is what the container's bind of `/tmp/.cmds` is independent of.
      assert Mounts.scratch(mounts) == Path.join(Paths.sandbox_root(), name)
      refute Mounts.host_scratch?(mounts)
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
