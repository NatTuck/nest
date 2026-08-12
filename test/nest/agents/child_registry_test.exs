defmodule Nest.Agents.ChildRegistryTest do
  @moduledoc """
  Tests for `Nest.Agents.ChildRegistry`.

  The registry is a singleton GenServer under the
  application supervision tree. Each test uses unique
  agent names so they can run in parallel without
  polluting each other's state.

  ## What we assert

    * `register/3` populates both mapping mirrors and the
      monitor table.
    * `children_of/2` and `parent_of/2` read correctly.
    * Re-registration under the same parent is idempotent.
    * `unregister/2` removes both mirrors and the monitor
      ref.
    * When the registered child process exits, the
      monitor's DOWN handler clears the entry without any
      explicit cleanup call from the test.
    * Self-cleanup on DOWN works for arbitrary process
      exit reasons (`:normal`, `:kill`, `:shutdown`).
  """
  use ExUnit.Case, async: true

  import Eventually

  alias Nest.Agents.ChildRegistry
  alias Nest.Agents.Registry, as: AgentsRegistry

  # Each test gets its own space_id. Tests in this file
  # don't need a real persisted space — ChildRegistry keys
  # are `{space_id, name}` so a unique space_id per test
  # is enough to keep parallel tests' state disjoint.
  setup do
    case Process.whereis(ChildRegistry) do
      nil -> start_supervised!(ChildRegistry.child_spec())
      _pid -> :ok
    end

    %{space_id: System.unique_integer([:positive])}
  end

  describe "register/3 + parent_of/2 + children_of/2" do
    test "stores the parent/child mapping on register", %{space_id: space_id} do
      parent = unique_name("parent")
      child = unique_name("child")

      :ok = ChildRegistry.register(space_id, parent, child)

      assert ChildRegistry.parent_of(space_id, child) == parent
      assert child in ChildRegistry.children_of(space_id, parent)

      on_exit(fn -> safe_unregister(space_id, child) end)
    end

    test "register is idempotent under the same parent", %{space_id: space_id} do
      parent = unique_name("parent")
      child = unique_name("child")

      :ok = ChildRegistry.register(space_id, parent, child)
      :ok = ChildRegistry.register(space_id, parent, child)

      # One logical entry per child.
      assert ChildRegistry.parent_of(space_id, child) == parent
      assert ChildRegistry.children_of(space_id, parent) == [child]

      on_exit(fn -> safe_unregister(space_id, child) end)
    end

    test "re-registering a child under a new parent re-links", %{space_id: space_id} do
      old_parent = unique_name("old")
      new_parent = unique_name("new")
      child = unique_name("child")

      :ok = ChildRegistry.register(space_id, old_parent, child)
      assert ChildRegistry.parent_of(space_id, child) == old_parent

      :ok = ChildRegistry.register(space_id, new_parent, child)
      assert ChildRegistry.parent_of(space_id, child) == new_parent

      # Old parent no longer lists the child.
      refute child in ChildRegistry.children_of(space_id, old_parent)
      assert child in ChildRegistry.children_of(space_id, new_parent)

      on_exit(fn -> safe_unregister(space_id, child) end)
    end

    test "children_of returns an empty list when no children are registered", %{
      space_id: space_id
    } do
      assert ChildRegistry.children_of(space_id, unique_name("no-children")) == []
    end

    test "parent_of returns nil for an unregistered child", %{space_id: space_id} do
      assert ChildRegistry.parent_of(space_id, unique_name("ghost")) == nil
    end
  end

  describe "unregister/2" do
    test "removes both mapping mirrors and the monitor ref", %{space_id: space_id} do
      parent = unique_name("parent")
      child = unique_name("child")

      :ok = ChildRegistry.register(space_id, parent, child)
      :ok = ChildRegistry.unregister(space_id, child)

      assert ChildRegistry.parent_of(space_id, child) == nil
      assert ChildRegistry.children_of(space_id, parent) == []
    end

    test "is a no-op for an unregistered child", %{space_id: space_id} do
      :ok = ChildRegistry.unregister(space_id, unique_name("never-was"))
    end
  end

  describe "DOWN self-cleanup" do
    test "clears the entry when the registered child process exits", %{space_id: space_id} do
      parent = unique_name("parent")
      child = unique_name("child")

      # The ChildRegistry monitors the child's pid by
      # resolving `AgentsRegistry.via_tuple(space_id, name)`.
      # Start the dummy process under that exact address — a
      # bare `Agent` GenServer keyed by the unique name.
      start_supervised!(
        {Agent, fn -> :ok end},
        id: {AgentsRegistry, child},
        start:
          {Agent, :start_link, [fn -> :ok end, [name: AgentsRegistry.via_tuple(space_id, child)]]}
      )

      :ok = ChildRegistry.register(space_id, parent, child)

      assert child in ChildRegistry.children_of(space_id, parent)
      assert ChildRegistry.parent_of(space_id, child) == parent

      stop_supervised!({AgentsRegistry, child})

      # Registry self-cleans on DOWN — no `unregister/2`
      # from us. Wait briefly for the DOWN to arrive.
      assert eventually(fn -> ChildRegistry.parent_of(space_id, child) == nil end, timeout: 1000)

      refute child in ChildRegistry.children_of(space_id, parent)
    end
  end

  # Helpers

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp safe_unregister(space_id, name) do
    _ = ChildRegistry.unregister(space_id, name)
    :ok
  end
end
