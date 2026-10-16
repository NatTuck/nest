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
  alias Nest.Spaces

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Start a live agent in `space_id` under an explicit name, and register the
  # same teardown `AgentTestHelpers.start_agent/1` uses (the agent is not
  # linked to the test process).
  defp start_named(space_id, name) do
    {:ok, ^name} =
      Agents.create_agent(
        space_id,
        %{name: "qwen3.5-plus", provider: "model-studio"},
        name: name,
        vocation_id: AgentTestHelpers.vocation_id_for_test()
      )

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

      # Different roots, so the same name is a different directory: no rule.
      assert start_named(bwrap_space, name) == name
      assert TmpSpace.agent_dir(none_space, name, "none") == "/tmp/#{name}"
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
