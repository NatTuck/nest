defmodule Nest.ParseCacheTest do
  @moduledoc """
  `Nest.ParseCache`'s own contract: the key is the file's bytes, and a path
  keeps one entry.
  """

  use ExUnit.Case, async: true

  alias Nest.ParseCache

  test "a path caches per content, and content it has not seen is a miss" do
    path = unique_path()

    assert ParseCache.fetch(path, "one") == :miss

    assert :ok = ParseCache.put(path, "one", :first)
    assert ParseCache.fetch(path, "one") == {:ok, :first}

    # The property that lets the cache do without a clock and without an
    # identity: content it has not seen is never served a parse of content it
    # has.
    assert ParseCache.fetch(path, "two") == :miss

    assert :ok = ParseCache.put(path, "two", :second)
    assert ParseCache.fetch(path, "two") == {:ok, :second}

    # And the first revision is gone rather than merely shadowed, so a path
    # holds one entry however often a file is rewritten. That is the table's
    # size, not its correctness: had the entry stayed it would still have been
    # the right answer for those bytes.
    assert ParseCache.fetch(path, "one") == :miss
  end

  test "a failure is cached as readily as a success" do
    path = unique_path()

    # Callers rely on this: `Nest.ProjectConfig` logs a malformed `.nest` once
    # per revision, which only holds if the failure itself is what was cached.
    assert :ok = ParseCache.put(path, "bad", {:error, "nope"})
    assert ParseCache.fetch(path, "bad") == {:ok, {:error, "nope"}}
  end

  test "two paths do not share an entry, even for identical content" do
    path = unique_path()
    other = unique_path()

    assert :ok = ParseCache.put(path, "same", :for_path)
    assert :ok = ParseCache.put(other, "same", :for_other)

    assert ParseCache.fetch(path, "same") == {:ok, :for_path}
    assert ParseCache.fetch(other, "same") == {:ok, :for_other}
  end

  # A path is only ever a cache key here, so nothing is created on disk and
  # nothing needs cleaning up; uniqueness is what keeps concurrent tests apart.
  defp unique_path do
    Path.join(System.tmp_dir!(), "parse_cache_#{System.unique_integer([:positive])}.toml")
  end
end
