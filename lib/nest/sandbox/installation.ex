defmodule Nest.Sandbox.Installation do
  @moduledoc """
  The stable name of *this* Nest installation, for the host resources it keeps
  outside the BEAM.

  One docker daemon can serve two installations that share a database schema —
  a development checkout and a production one, say — and their space ids are
  unrelated serials that collide: space 7 in each. A container named after the
  space id alone would then be *shared* by two installations whose spaces have
  nothing to do with each other, and the second one to run would adopt the
  first's container, its binds, and its `/tmp`.

  So every name the docker backend builds outside the BEAM carries this
  segment, derived from the one thing that distinguishes two installations on
  one machine: the configured database name. It is stable for the life of an
  installation (it is configuration, not state), which is what lets a container
  outlive a BEAM restart.

  This reads the Repo's **configured database name** — configuration, not the
  spaces schema, which nothing under `lib/nest/sandbox/` may read.
  """

  # A docker object name may contain only `[a-zA-Z0-9_.-]`, and the segment is
  # never the first character of a name (it always follows a `-`), so sanitising
  # is all that is needed. The bound keeps a pathological database name from
  # making an unwieldy name; two installations whose names agree for their first
  # 40 characters would collide, which is a bug in the deployment, not here.
  @max_length 40
  @fallback "default"
  @unsafe ~r/[^A-Za-z0-9_.-]/

  @doc """
  The installation segment, safe to use as one `-`-separated part of a docker
  object name.
  """
  @spec segment() :: String.t()
  def segment do
    case configured_database() do
      name when is_binary(name) and name != "" -> sanitize(name)
      _other -> @fallback
    end
  end

  defp configured_database do
    :nest
    |> Application.get_env(Nest.Repo, [])
    |> database_of()
  end

  defp database_of(config) when is_list(config), do: Keyword.get(config, :database)
  defp database_of(_config), do: nil

  defp sanitize(name) do
    segment = name |> String.replace(@unsafe, "_") |> String.slice(0, @max_length)

    # A name that sanitised away to nothing must not leave a trailing `-`.
    if String.trim(segment, "_.") == "", do: @fallback, else: segment
  end
end
