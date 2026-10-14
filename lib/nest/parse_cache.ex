defmodule Nest.ParseCache do
  @moduledoc """
  Memoizes the parse of a configuration file, keyed on the file's own bytes.

  A caller reads its file on every load — that read is how it learns whether
  anything changed — and then asks this cache for the parse of the bytes it
  read. The expensive half, decoding and validating the text, is done once per
  distinct revision instead of once per load. `Nest.DotConfig` (which parses
  `config.toml` and `local.toml`) and `Nest.ProjectConfig` (which parses a
  project's `.nest`) both work this way.

  Keying on the content is what makes the cache correct by construction. A file
  that changed at all is a different key, so there is no identity to compare, no
  clock to trust, and nothing that can collide: two revisions of a file can
  never share an entry, however alike their mtimes and lengths happen to be.
  Nothing here needs to know who wrote the file or when, which is why no writer
  has anything to invalidate, and why an edit made outside the application is
  seen for exactly the same reason as one the application made.

  One entry per path is kept: `put/3` drops the path's previous entry, so a file
  rewritten repeatedly leaves one entry behind rather than one per revision.
  """

  @table :nest_parse_cache

  @doc """
  The result cached for `content` under `path`, or `:miss`.
  """
  @spec fetch(Path.t(), binary()) :: {:ok, term()} | :miss
  def fetch(path, content) do
    case :ets.lookup(table(), {path, content}) do
      [{_, result}] -> {:ok, result}
      [] -> :miss
    end
  end

  @doc """
  Cache `result` as the parse of `content`, replacing whatever `path` had cached
  before.

  `result` may be a failure. A parse that failed for a given revision of a file
  is as cacheable as one that succeeded, and a caller whose contract is to
  report a failure once — by logging it, say — depends on that: it is the cache,
  not the caller, that remembers the failure for those bytes.
  """
  @spec put(Path.t(), binary(), term()) :: :ok
  def put(path, content, result) do
    table = table()
    :ets.match_delete(table, {{path, :_}, :_})
    :ets.insert(table, {{path, content}, result})
    :ok
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> new_table()
      _ -> @table
    end
  end

  # Two processes can race the `whereis` check during app start (a config scan
  # and a request path both load config concurrently), so the loser of the
  # `:ets.new` race adopts the winner's table.
  defp new_table do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
  rescue
    ArgumentError -> @table
  end
end
