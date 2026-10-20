defmodule Nest.Agents.RegistryTest do
  @moduledoc """
  Tests for the Agent Registry module.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.Registry

  describe "child_spec/0" do
    test "returns registry child spec" do
      # `type: :supervisor` is not asserted: `Registry.child_spec/1` sets it for
      # every option set, so it cannot tell a correct `name:`/`keys:` from a
      # wrong one. The id is derived from the `name:` option we pass, so it is
      # the one field this function actually decides.
      assert Registry.child_spec().id == Nest.Agents.Registry
    end
  end

  describe "via_tuple/2" do
    test "returns via tuple for agent lookup" do
      result = Registry.via_tuple(1, "clever-raven")
      assert elem(result, 0) == :via
      assert elem(result, 2) == {Nest.Agents.Registry, {1, "clever-raven"}}
    end
  end
end
