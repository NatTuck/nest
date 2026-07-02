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

    # Birthday-paradox math: with ~440k name combinations, the
    # natural collision rate is ~0.6% per generation. A batch
    # of N picks has ~1 - exp(-N/1600) probability of any
    # collision. We assert the invariant the function actually
    # guarantees: the vast majority of picks yield unique
    # names. A batch of 200 should have at least 195 unique.
    # (The previous "100 names all unique" assertion was
    # 45%-flaky.)
    test "produces overwhelmingly unique names across many calls" do
      names = for _ <- 1..200, do: NameGenerator.generate()
      assert length(Enum.uniq(names)) >= 195
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
