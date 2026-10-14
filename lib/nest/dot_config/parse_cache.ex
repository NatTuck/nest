defmodule Nest.DotConfig.ParseCache do
  @moduledoc """
  Memoizes `Nest.DotConfig`'s parse of a config file, keyed on the file's own
  bytes.

  `Nest.DotConfig.load/1` reads the file on every call — that read is how it
  learns whether anything changed. This cache keeps the expensive half of a
  load, the TOML decode and the parse, from being redone for bytes that have
  already been seen.

  Keying on the content is what makes it correct by construction. A file that
  changed at all is a different key, so there is no identity to compare, no
  clock to trust, and nothing that can collide: two revisions of a file can
  never share an entry, however alike their mtimes and lengths happen to be.
  Nothing here needs to know who wrote the file or when, which is why no writer
  has anything to invalidate, and why an edit made outside the application is
  seen for exactly the same reason as one the application made.

  One entry per path is kept: `put/3` drops the path's previous entry, so a file
  rewritten repeatedly leaves one entry behind rather than one per revision.
  """

  @table :nest_dotconfig_parse_cache

  @doc """
  The parse cached for `content` under `path`, or `:miss`.
  """
  @spec fetch(Path.t(), binary()) :: {:ok, term()} | :miss
  def fetch(path, content) do
    case :ets.lookup(table(), {path, content}) do
      [{_, config}] -> {:ok, config}
      [] -> :miss
    end
  end

  @doc """
  Cache `config` as the parse of `content`, replacing whatever `path` had cached
  before.
  """
  @spec put(Path.t(), binary(), term()) :: :ok
  def put(path, content, config) do
    table = table()
    :ets.match_delete(table, {{path, :_}, :_})
    :ets.insert(table, {{path, content}, config})
    :ok
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> new_table()
      _ -> @table
    end
  end

  # Two processes can race the `whereis` check during app start (the Models
  # scan and the endpoint probe both load config concurrently), so the loser of
  # the `:ets.new` race adopts the winner's table.
  defp new_table do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
  rescue
    ArgumentError -> @table
  end
end
