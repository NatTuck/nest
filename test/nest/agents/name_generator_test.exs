defmodule Nest.Agents.NameGeneratorTest do
  @moduledoc """
  Tests for the NameGenerator module.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.NameGenerator

  describe "generate/0" do
    test "generates name in adjective-animal format" do
      name = NameGenerator.generate()
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)
    end

    test "generates unique names across multiple calls" do
      names = for _ <- 1..100, do: NameGenerator.generate()
      assert length(Enum.uniq(names)) == length(names)
    end
  end

  describe "generate_unique/1" do
    test "generates unique name avoiding existing names" do
      existing = MapSet.new(["clever-raven"])
      name = NameGenerator.generate_unique(existing)
      refute MapSet.member?(existing, name)
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)
    end

    test "returns name when no collision" do
      existing = MapSet.new()
      name = NameGenerator.generate_unique(existing)
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)
    end

    test "regenerates on collision" do
      # Force collision by providing a MapSet with the first generated name
      first_name = NameGenerator.generate()
      existing = MapSet.new([first_name])

      # Generate another unique name
      new_name = NameGenerator.generate_unique(existing)
      refute new_name == first_name
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, new_name)
    end
  end
end
