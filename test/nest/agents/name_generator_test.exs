defmodule Nest.Agents.NameGeneratorTest do
  @moduledoc """
  Tests for the NameGenerator module.
  """
  use ExUnit.Case, async: true

  alias Nest.Agents.NameGenerator
  alias UniqueNamesGenerator.Dictionaries

  describe "generate/0" do
    test "draws one word from each configured dictionary, lowercased and joined" do
      # All `generate/0` is, is its configuration, so that is what this pins:
      # an adjective from one list, an animal from the other, joined by the
      # separator the module sets. A uniqueness-over-N-draws assertion used to
      # stand here, but with 1_202 x 355 combinations the chance of even one
      # collision in 200 draws is ~5%, so it could only fail if the
      # dictionaries degenerated — which this catches deterministically, in
      # microseconds, with no randomness and no lazy dictionary load.
      assert [adjective, animal] = String.split(NameGenerator.generate(), "-")

      assert adjective in Dictionaries.Adjectives.list_all()
      assert animal in Dictionaries.Animals.list_all()
    end
  end

  describe "generate_unique/1" do
    test "generates unique name avoiding existing names" do
      existing = MapSet.new(["clever-raven"])
      name = NameGenerator.generate_unique(existing)
      refute MapSet.member?(existing, name)
      assert Regex.match?(~r/^[a-z]+-[a-z]+$/, name)
    end
  end

  describe "generate_unique/2" do
    test "retries past candidates that are already taken" do
      # The retry is the module's own logic and cannot be reached through the
      # real generator without drawing until a name happens to repeat, so the
      # candidate source is injected: the first candidate is taken, the second
      # is free.
      Process.put(:candidate, 0)

      generate = fn ->
        n = Process.get(:candidate, 0)
        Process.put(:candidate, n + 1)
        if n == 0, do: "clever-raven", else: "swift-fox"
      end

      assert NameGenerator.generate_unique(MapSet.new(["clever-raven"]), generate) == "swift-fox"
    end

    test "raises once every candidate is taken" do
      # The give-up is what bounds the recursion: a name space that is
      # genuinely exhausted would otherwise spin forever.
      assert_raise RuntimeError, ~r/Could not generate unique name after \d+ attempts/, fn ->
        NameGenerator.generate_unique(MapSet.new(["clever-raven"]), fn -> "clever-raven" end)
      end
    end
  end
end
