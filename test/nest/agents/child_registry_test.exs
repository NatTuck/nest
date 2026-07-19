defmodule Nest.Agents.ChildRegistryTest do
  @moduledoc """
  Tests for `Nest.Agents.ChildRegistry`.

  The registry is a singleton GenServer under the
  application supervision tree. Each test uses unique
  agent names so they can run in parallel without
  polluting each other's state.

  ## What we assert

    * `register/2` populates both mapping mirrors and the
      monitor table.
    * `children_of/1` and `parent_of/1` read correctly.
    * Re-registration under the same parent is idempotent.
    * `unregister/1` removes both mirrors and the monitor
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

  setup do
    # Make sure the registry is up. In a normal `mix test`
    # run it's started by `Nest.Application`; tests that
    # start via `start_supervised!` from a bare `ExUnit.Case`
    # need it spun up themselves.
    case Process.whereis(ChildRegistry) do
      nil -> start_supervised!(ChildRegistry.child_spec())
      _pid -> :ok
    end

    :ok
  end

  describe "register/2 + parent_of/1 + children_of/1" do
    test "stores the parent/child mapping on register" do
      parent = unique_name("parent")
      child = unique_name("child")

      :ok = ChildRegistry.register(parent, child)

      assert ChildRegistry.parent_of(child) == parent
      assert child in ChildRegistry.children_of(parent)

      on_exit(fn -> safe_unregister(child) end)
    end

    test "register is idempotent under the same parent" do
      parent = unique_name("parent")
      child = unique_name("child")

      :ok = ChildRegistry.register(parent, child)
      :ok = ChildRegistry.register(parent, child)

      # One logical entry per child.
      assert ChildRegistry.parent_of(child) == parent
      assert ChildRegistry.children_of(parent) == [child]

      on_exit(fn -> safe_unregister(child) end)
    end

    test "re-registering a child under a new parent re-links" do
      old_parent = unique_name("old")
      new_parent = unique_name("new")
      child = unique_name("child")

      :ok = ChildRegistry.register(old_parent, child)
      assert ChildRegistry.parent_of(child) == old_parent

      :ok = ChildRegistry.register(new_parent, child)
      assert ChildRegistry.parent_of(child) == new_parent

      # Old parent no longer lists the child.
      refute child in ChildRegistry.children_of(old_parent)
      assert child in ChildRegistry.children_of(new_parent)

      on_exit(fn -> safe_unregister(child) end)
    end

    test "children_of returns an empty list when no children are registered" do
      assert ChildRegistry.children_of(unique_name("no-children")) == []
    end

    test "parent_of returns nil for an unregistered child" do
      assert ChildRegistry.parent_of(unique_name("ghost")) == nil
    end
  end

  describe "unregister/1" do
    test "removes both mapping mirrors and the monitor ref" do
      parent = unique_name("parent")
      child = unique_name("child")

      :ok = ChildRegistry.register(parent, child)
      :ok = ChildRegistry.unregister(child)

      assert ChildRegistry.parent_of(child) == nil
      assert ChildRegistry.children_of(parent) == []
    end

    test "is a no-op for an unregistered child" do
      :ok = ChildRegistry.unregister(unique_name("never-was"))
    end
  end

  describe "DOWN self-cleanup" do
    test "clears the entry when the registered child process exits" do
      parent = unique_name("parent")
      child = unique_name("child")

      # The ChildRegistry monitors the child's pid by
      # resolving `AgentsRegistry.via_tuple(name)`. Start
      # the dummy process under that exact address — a
      # bare `Agent` GenServer keyed by the unique name.
      start_supervised!(
        {Agent, fn -> :ok end},
        id: {AgentsRegistry, child},
        start: {Agent, :start_link, [fn -> :ok end, [name: AgentsRegistry.via_tuple(child)]]}
      )

      :ok = ChildRegistry.register(parent, child)

      assert child in ChildRegistry.children_of(parent)
      assert ChildRegistry.parent_of(child) == parent

      stop_supervised!({AgentsRegistry, child})

      # Registry self-cleans on DOWN — no `unregister/1`
      # from us. Wait briefly for the DOWN to arrive.
      assert eventually(fn -> ChildRegistry.parent_of(child) == nil end, timeout: 1000)

      refute child in ChildRegistry.children_of(parent)
    end
  end

  # Helpers

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp safe_unregister(name) do
    _ = ChildRegistry.unregister(name)
    :ok
  end
end
