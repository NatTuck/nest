defmodule Nest.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Nest.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Nest.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Nest.DataCase
    end
  end

  setup tags do
    Nest.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  Tests tagged with `:db_shared` (or that match the optional second
  argument) opt into `shared: true`, which lets spawned children
  (e.g. an `Agent` GenServer whose `init/1` queries the DB) use
  the test's checked-out connection without a separate
  `Sandbox.allow/3` call. This is needed for async tests that
  start a GenServer doing DB work in `init/1`; without it, the
  GenServer's `init/1` fails with `DBConnection.OwnershipError`.
  """
  def setup_sandbox(tags, db_shared_tag \\ :db_shared) do
    shared = tags[db_shared_tag] || not tags[:async]
    pid = Sandbox.start_owner!(Nest.Repo, shared: shared)
    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
