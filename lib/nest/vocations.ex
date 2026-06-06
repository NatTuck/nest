defmodule Nest.Vocations do
  @moduledoc """
  The Nest.Vocations context.
  """

  import Ecto.Query, warn: false
  alias Nest.Repo

  alias Nest.Vocations.Vocation

  @doc """
  Returns the list of vocations.

  ## Examples

      iex> list_vocations()
      [%Vocation{}, ...]

  """
  def list_vocations do
    Repo.all(Vocation)
  end

  @doc """
  Gets a single vocation.

  Raises `Ecto.NoResultsError` if the Vocation does not exist.

  ## Examples

      iex> get_vocation!(123)
      %Vocation{}

      iex> get_vocation!(456)
      ** (Ecto.NoResultsError)

  """
  def get_vocation!(id), do: Repo.get!(Vocation, id)

  @doc """
  Gets a single vocation.

  Returns `nil` if the Vocation does not exist.

  ## Examples

      iex> get_vocation(123)
      %Vocation{}

      iex> get_vocation(456)
      nil

  """
  def get_vocation(id), do: Repo.get(Vocation, id)

  @doc """
  Creates a vocation.

  ## Examples

      iex> create_vocation(%{field: value})
      {:ok, %Vocation{}}

      iex> create_vocation(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_vocation(attrs) do
    %Vocation{}
    |> Vocation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a vocation.

  ## Examples

      iex> update_vocation(vocation, %{field: new_value})
      {:ok, %Vocation{}}

      iex> update_vocation(vocation, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_vocation(%Vocation{} = vocation, attrs) do
    vocation
    |> Vocation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a vocation.

  ## Examples

      iex> delete_vocation(vocation)
      {:ok, %Vocation{}}

      iex> delete_vocation(vocation)
      {:error, %Ecto.Changeset{}}

  """
  def delete_vocation(%Vocation{} = vocation) do
    Repo.delete(vocation)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking vocation changes.

  ## Examples

      iex> change_vocation(vocation)
      %Ecto.Changeset{data: %Vocation{}}

  """
  def change_vocation(%Vocation{} = vocation, attrs \\ %{}) do
    Vocation.changeset(vocation, attrs)
  end
end
