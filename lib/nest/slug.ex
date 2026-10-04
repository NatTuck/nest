defmodule Nest.Slug do
  @moduledoc """
  Derives a URL-safe slug from a human-readable name.

  Shared by the `Space`, `Blueprint`, and `Vocation` schemas so their
  auto-generated slugs can't drift. Lowercases the name, collapses every
  run of non-alphanumeric characters to a single `-`, and trims leading
  and trailing dashes.
  """

  @doc """
  Slugify `name`. Returns `nil` for non-binary input so callers can
  treat "no name" as "no slug".
  """
  @spec from_name(String.t() | nil) :: String.t() | nil
  def from_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  def from_name(nil), do: nil
end
