defmodule Nest.BlueprintsFixtures do
  @moduledoc """
  Test helpers for creating blueprints via the
  `Nest.Blueprints` context.
  """

  alias Nest.VocationsFixtures

  @doc """
  Generate a blueprint. The blueprint's `root_vocation` (slug)
  defaults to a fresh `Default`-style vocation, so callers
  don't have to worry about FK setup. Override with
  `:root_vocation` to point at a specific vocation slug.
  """
  def blueprint_fixture(attrs \\ %{}) do
    root_vocation =
      case Map.get(attrs, :root_vocation) do
        nil -> VocationsFixtures.vocation_fixture().slug
        slug -> slug
      end

    {:ok, blueprint} =
      attrs
      |> Enum.into(%{
        description: "some description",
        name: "blueprint-#{System.unique_integer([:positive])}",
        root_vocation: root_vocation,
        spawnable_vocations: []
      })
      |> Nest.Blueprints.create_blueprint()

    blueprint
  end
end
