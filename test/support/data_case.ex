defmodule Nest.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. Database tests can
  be run asynchronously by setting `use Nest.DataCase,
  async: true`.
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
  Sets up the sandbox by checking out a connection in the test
  process itself.

  The test pid becomes the connection owner. Processes spawned by
  the test (via `start_supervised!` etc.) inherit `$callers` from
  the test process, and any `Repo` call inside them walks the
  caller chain via `proxy_for/2`, hitting the test's connection
  automatically. This means **no `Sandbox.allow/3` is needed per
  child pid**, regardless of how deeply the agent tree is nested.

  Sync tests (`async: false`) opt into `shared: true` because
  they don't have parallel siblings to fight for the repo-wide
  shared lock. Async tests default to `shared: false`; the test
  pid still owns the connection but no other process holds the
  shared flag, so concurrent async tests don't collide.

  Note: the `{:shared, pid}` ownership mode is REPO-WIDE — only
  one process can hold it at a time, so any test (sync or async)
  that uses `shared: true` serializes against other shared-mode
  tests. Use `:db_shared` only when a test needs shared mode and
  cannot pre-fetch its DB data in the test process.
  """
  def setup_sandbox(tags, db_shared_tag \\ :db_shared) do
    parent = self()

    case Sandbox.checkout(Nest.Repo, []) do
      :ok ->
        if tags[db_shared_tag] || not tags[:async] do
          Sandbox.mode(Nest.Repo, {:shared, parent})
        end

        on_exit(fn -> Sandbox.checkin(Nest.Repo, []) end)

      {:already, _kind} ->
        # Already checked out by an ancestor setup; nothing to do.
        :ok
    end
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
