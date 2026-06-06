defmodule Nest.VocationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Nest.Vocations` context.
  """

  @doc """
  Generate a vocation.
  """
  def vocation_fixture(attrs \\ %{}) do
    {:ok, vocation} =
      attrs
      |> Enum.into(%{
        description: "some description",
        modes: %{},
        name: "some name",
        system_prompt: "some system_prompt",
        tools: []
      })
      |> Nest.Vocations.create_vocation()

    vocation
  end
end
