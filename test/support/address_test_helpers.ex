defmodule Nest.AddressTestHelpers do
  @moduledoc """
  The two fixtures the addressing half needs: a **human** and a space that human
  is in.

  A human is a `users` row — that is what an `@<username>` address resolves to
  (`Nest.Accounts.get_user_by_username/1`) — and the space's human is its owner
  (`spaces.created_by_user_id`), which is what
  `Nest.Notes.list_humans_for_space/1` reads. A space has no membership table
  (`notes/multiple-users.md`), so "the space's humans" is its owner.

  The row is inserted directly rather than through `Nest.Accounts.create_user/2`:
  nothing here logs in, and the argon2 hash that path computes is the slowest
  thing in the suite.
  """

  alias Nest.Accounts.User
  alias Nest.Agents.AgentTestHelpers
  alias Nest.Repo
  alias Nest.Spaces

  @doc """
  A `users` row named `username`.

  The name is stored as given, so a test that wants to prove `@Nat` folds should
  ask for `"nat"` and address `@Nat`.
  """
  @spec human(String.t()) :: User.t()
  def human(username) do
    Repo.insert!(%User{username: username, password_hash: "not-a-hash"})
  end

  @doc """
  A fresh space owned by `username` (created here), with a workspace of its own.

  `attrs` are merged over the defaults, so a test can name the slug or the
  backend.
  """
  @spec space_with_human(String.t(), map()) :: Nest.Spaces.Space.t()
  def space_with_human(username, attrs \\ %{}) do
    user = human(username)
    unique = System.unique_integer([:positive])

    {:ok, space} =
      Spaces.create_space(
        user.id,
        Map.merge(
          %{
            name: "address-space-#{unique}",
            slug: "address-space-#{unique}",
            workspace_path: AgentTestHelpers.default_test_workspace()
          },
          attrs
        )
      )

    space
  end
end
