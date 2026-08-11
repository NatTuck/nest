defmodule Nest.BlueprintsFixtures do
  @moduledoc """
  Test helpers for creating blueprints via the
  `Nest.Blueprints` context.
  """

  alias Nest.VocationsFixtures

  @doc """
  Generate a blueprint. The blueprint's `root_vocation_id`
  defaults to a fresh `Default`-style vocation, so callers
  don't have to worry about FK setup. Override with
  `:root_vocation_id` to point at a specific vocation row.
  """
  def blueprint_fixture(attrs \\ %{}) do
    {:ok, vocation} =
      Map.get(attrs, :root_vocation_id)
      |> case do
        nil -> {:ok, VocationsFixtures.vocation_fixture()}
        _vid -> {:ok, nil}
      end

    {:ok, blueprint} =
      attrs
      |> Enum.into(%{
        description: "some description",
        name: "blueprint-#{System.unique_integer([:positive])}",
        root_vocation_id: vocation && vocation.id,
        spawnable_vocation_ids: []
      })
      |> Nest.Blueprints.create_blueprint()

    blueprint
  end
end
