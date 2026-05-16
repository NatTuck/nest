defmodule Nest.Agents.NameGenerator do
  @moduledoc """
  Generates unique, readable agent IDs using adjective-animal combinations.

  Uses the unique_names_generator library with custom configuration
  to produce names like "clever-raven" or "swift-fox".
  """

  @dictionaries [:adjectives, :animals]
  @separator "-"
  @max_attempts 100

  @doc """
  Generates a random readable name in adjective-animal format.

  Returns a string like "clever-raven" or "swift-fox".

  ## Examples

      iex> Nest.Agents.NameGenerator.generate()
      "clever-raven"

  """
  @spec generate() :: String.t()
  def generate do
    UniqueNamesGenerator.generate(@dictionaries, %{
      separator: @separator,
      style: :lowercase
    })
  end

  @doc """
  Generates a unique name that doesn't exist in the provided set.

  Takes a MapSet of existing names and keeps generating until it finds
  one that isn't in the set. Raises if it can't find a unique name
  after max_attempts.

  ## Examples

      iex> existing = MapSet.new(["clever-raven"])
      iex> Nest.Agents.NameGenerator.generate_unique(existing)
      "swift-fox"

  """
  @spec generate_unique(MapSet.t(String.t())) :: String.t()
  def generate_unique(existing) do
    do_generate_unique(existing, 0)
  end

  defp do_generate_unique(_existing, attempts) when attempts >= @max_attempts do
    raise "Could not generate unique name after #{@max_attempts} attempts"
  end

  defp do_generate_unique(existing, attempts) do
    name = generate()

    if MapSet.member?(existing, name) do
      do_generate_unique(existing, attempts + 1)
    else
      name
    end
  end
end
