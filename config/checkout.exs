defmodule Nest.Config.Checkout do
  @moduledoc """
  Which checkout this is, and the database and port it therefore uses.

  ## The rule

  A checkout must **never** silently adopt another checkout's database. Two
  checkouts are named on purpose:

    * `nest` — the primary checkout: port 4040, `nest_dev` / `nest_test`
    * `nest2` — the instance that edits it: port 4042, `nest_dev2` / `nest_test2`

  **Every other checkout gets the scratch slot**: port 4044 and
  `nest_dev_scratch`. That used to be the opposite — anything not called `nest`
  landed on `nest_dev2`, so every worktree shared the database `nest2` serves
  from. A migration run from a worktree then changed the schema underneath a
  running `nest2`, and a data migration renamed rows in it. The default has to
  be the safe direction.

  The set is deliberately small: two named databases plus one scratch. A second
  worktree that needs its own dev database says so —
  `NEST_DEV_DB=nest_dev_scratch2` — rather than being given one by a naming
  scheme. Two unnamed checkouts running servers at once share
  `nest_dev_scratch`, which is disposable and separable; neither can reach
  `nest_dev2`.

  ## Test databases

  Same shape, using the `MIX_TEST_PARTITION` mechanism this project already
  documented but did not implement:

    * `nest` — `nest_test`
    * `nest2` — `nest_test2`
    * anything else — `nest_test1`, or `nest_test<MIX_TEST_PARTITION>`

  `mix test`'s alias creates and migrates whichever one it lands on, so
  isolation costs nothing.

  ## Overrides win

  `NEST_DEV_DB`, `NEST_TEST_DB` and `NEST_PORT` beat everything above, so
  pointing a checkout at a particular database is a decision you make on
  purpose rather than one this module guesses.

  ## The scratch database does not exist until you make it

  `mix ecto.create` makes it, and `mix ecto.setup` seeds it. For real data, a
  template copy of the primary is seconds and needs no dump:

      createdb -T nest_dev nest_dev_scratch

  (It needs no open connections on `nest_dev`, so stop that server first, or use
  `pg_dump nest_dev | psql nest_dev_scratch`.)
  """

  @named %{
    "nest" => %{port: 4040, database: "nest_dev", test_partition: ""},
    "nest2" => %{port: 4042, database: "nest_dev2", test_partition: "2"}
  }

  # The slot every unnamed checkout gets. One dev database, one port, one test
  # database — small on purpose, and overridable per checkout.
  @scratch_database "nest_dev_scratch"
  @scratch_port 4044
  @scratch_test_partition "1"

  @doc "The name of the checkout directory we are running from."
  @spec name() :: String.t()
  def name, do: File.cwd!() |> Path.basename()

  @doc "The dev instance's port and database, for this checkout."
  @spec dev() :: %{port: pos_integer(), database: String.t()}
  def dev, do: dev(name())

  @doc """
  The dev instance's port and database, for the named checkout.

  Taking the name as an argument is what lets a test pin the table — which is
  the whole safety property here, and not something to leave to a `case` nobody
  can exercise.
  """
  @spec dev(String.t()) :: %{port: pos_integer(), database: String.t()}
  def dev(checkout) do
    named = Map.get(@named, checkout)

    %{
      port: env_integer("NEST_PORT") || (named && named.port) || @scratch_port,
      database: env("NEST_DEV_DB") || (named && named.database) || @scratch_database
    }
  end

  @doc "The test database name, for this checkout."
  @spec test_database() :: String.t()
  def test_database, do: test_database(name())

  @doc "The test database name, for the named checkout."
  @spec test_database(String.t()) :: String.t()
  def test_database(checkout) do
    named = Map.get(@named, checkout)

    env("NEST_TEST_DB") ||
      "nest_test" <>
        (env("MIX_TEST_PARTITION") || (named && named.test_partition) || @scratch_test_partition)
  end

  defp env(var) do
    case System.get_env(var) do
      nil ->
        nil

      value ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end
    end
  end

  defp env_integer(var) do
    case env(var) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {port, ""} when port > 0 -> port
          _ -> raise ArgumentError, "#{var} must be a positive integer, got: #{inspect(value)}"
        end
    end
  end
end
