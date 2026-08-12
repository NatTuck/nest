defmodule Nest.Agents.RegistryTest do
  @moduledoc """
  Tests for the Agent Registry module.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Registry

  describe "child_spec/0" do
    test "returns registry child spec" do
      spec = Registry.child_spec()
      assert spec.type == :supervisor
      assert spec.id == Nest.Agents.Registry
    end
  end

  describe "via_tuple/2" do
    test "returns via tuple for agent lookup" do
      result = Registry.via_tuple(1, "clever-raven")
      assert elem(result, 0) == :via
      # The second element is Elixir's Registry module (used for via mechanism)
      assert is_atom(elem(result, 1))
      assert elem(result, 2) == {Nest.Agents.Registry, {1, "clever-raven"}}
    end
  end

  describe "lookup/2" do
    test "returns :error for non-existent agent" do
      # Registry is already started by Application
      assert {:error, :not_found} = Registry.lookup(1, "nonexistent-agent")
    end
  end
end
