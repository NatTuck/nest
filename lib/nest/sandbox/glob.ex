defmodule Nest.Sandbox.Glob do
  @moduledoc """
  The glob matcher backing `Nest.Sandbox.glob/5`.

  `split/1` breaks a resolved absolute pattern (in the *sandbox* spelling)
  into its longest literal prefix and the remaining glob segments. `walk/3`
  expands those segments under a directory.

  Glob metacharacters: `*` (any run of non-`/` chars), `?` (one non-`/`
  char), and `**` (any run of path segments, including none — matched across
  directory boundaries when it occupies a full segment).

  ## Host paths must not escape `Nest.Sandbox`

  `walk/3` receives a host directory and returns host paths; `Nest.Sandbox`
  translates them back to the sandbox spelling before they leave it. No
  caller other than `Nest.Sandbox` may use the host results.
  """

  @doc """
  Split a resolved absolute glob pattern (`full`, in the sandbox spelling)
  into `{base, rest}`: `base` is the longest leading literal prefix (no `*`
  or `?`), `rest` the remaining glob segments. The leading empty segment of
  an absolute path is preserved so `Path.join/1` yields an absolute base;
  when the first segment is itself a glob, the base collapses to `/`.
  """
  @spec split(String.t()) :: {String.t(), [String.t()]}
  def split(full) do
    segments = String.split(full, "/", trim: false)

    # The leading literal prefix (up to the FIRST glob segment) is the base
    # directory; everything from the first glob onward is `rest`. `split_while`
    # (unlike `split_with`) stops at the first glob, so a pattern like
    # `src/*/file.txt` keeps `file.txt` in `rest` — `do_glob_walk/4` matches
    # any later literal segment exactly via `fnmatch?/2`.
    {literal, glob} = Enum.split_while(segments, &(!glob_segment?(&1)))

    # `Path.join/1` drops the leading empty segment of an absolute path
    # (`["", "tmp", "x"]` → `"tmp/x"`), which would silently turn the base
    # into a CWD-relative path. Re-prepend `/` when the source was absolute.
    base =
      literal
      |> Path.join()
      |> maybe_make_absolute?(full)

    {base_dir_or_root(base), glob}
  end

  @doc """
  Expand `segments` under host directory `dir`, returning matched paths
  (host spelling). Throws `:glob_too_broad` when the running match count
  exceeds `limit` (so the caller can unwind early).
  """
  @spec walk(String.t(), [String.t()], pos_integer()) :: [String.t()]
  def walk(dir, segments, limit) do
    do_glob_walk(dir, segments, [], limit)
  end

  # Re-absolute a base that lost its leading `/` during `Path.join/1`.
  defp maybe_make_absolute?(base, full) do
    if String.starts_with?(full, "/") and not String.starts_with?(base, "/") do
      "/" <> base
    else
      base
    end
  end

  # The literal prefix joined is a full path, or the root when it's empty
  # (pattern starts with a glob). Left in the sandbox spelling; the caller
  # translates it to the host before walking.
  defp base_dir_or_root(""), do: "/"

  defp base_dir_or_root(path), do: path

  # A segment is a "glob" when it contains `*` or `?`.
  defp glob_segment?(seg), do: String.contains?(seg, "*") or String.contains?(seg, "?")

  # All segments consumed: the current `dir` is a full match.
  defp do_glob_walk(dir, [], acc, limit) do
    acc = [dir | acc]
    if length(acc) > limit, do: throw(:glob_too_broad)
    acc
  end

  # `**` occupies a full segment: match zero or more path segments.
  # We try each remaining segment against the directory contents and
  # recurse both one-level-deeper (into each subdir) and skipping
  # (treating `**` as matching zero segments).
  defp do_glob_walk(dir, ["**" | rest], acc, limit) do
    entries = safe_readdir(dir)

    # `**` may match zero segments: continue with `rest` in the same dir.
    acc = do_glob_walk(dir, rest, acc, limit)

    # `**` matches one-or-more segments: recurse into each subdir.
    acc =
      Enum.reduce(entries, acc, fn name, a ->
        child = Path.join(dir, name)

        if File.dir?(child) do
          do_glob_walk(child, ["**" | rest], a, limit)
        else
          a
        end
      end)

    acc
  end

  # A normal segment: match it against the directory contents.
  defp do_glob_walk(dir, [seg | rest], acc, limit) do
    entries = safe_readdir(dir)

    Enum.reduce_while(entries, acc, fn name, a ->
      if fnmatch?(seg, name) do
        child = Path.join(dir, name)
        {:cont, do_glob_walk(child, rest, a, limit)}
      else
        {:cont, a}
      end
    end)
  end

  # Return the directory's entries as basenames, or `[]` when the
  # directory doesn't exist / isn't readable (the glob simply matches
  # nothing there).
  defp safe_readdir(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  # Match a single glob segment (no `/`) against a basename. Supports
  # `*` (any run of characters) and `?` (exactly one character); every
  # other character is literal. `**` never reaches here — it occupies a
  # whole path segment and is handled by its own `do_glob_walk/4` clause.
  defp fnmatch?(pat, name), do: seg_match(pat, name)

  # Both exhausted: matched.
  defp seg_match(<<>>, <<>>), do: true
  # Pattern exhausted but name remains: only matches if the leftover
  # pattern was all stars (handled by the `*` clause below).
  defp seg_match(<<>>, _name), do: false
  # Name exhausted with a non-empty pattern remaining: no match (a
  # trailing `*` was already collapsed into the `*` clause).
  defp seg_match(_pat, <<>>), do: false
  # Leading `*`: collapse consecutive stars, then let the star consume
  # 0..N characters of the name.
  defp seg_match(<<"*"::utf8, rest::binary>>, name) do
    star_match(skip_stars(rest), name)
  end

  # `?` matches any single character.
  defp seg_match(<<"?"::utf8, rest::binary>>, <<_c::utf8, name_rest::binary>>) do
    seg_match(rest, name_rest)
  end

  # Literal character match.
  defp seg_match(<<p::utf8, rest::binary>>, <<n::utf8, name_rest::binary>>) when p == n do
    seg_match(rest, name_rest)
  end

  defp seg_match(_pat, _name), do: false

  # The star has consumed `k` characters of `name`; try to match the
  # remainder of the pattern (`rest`) against the leftover name. The
  # star may consume zero characters first, then one more, etc.
  defp star_match(rest, name) do
    if seg_match(rest, name) do
      true
    else
      case name do
        <<_c::utf8, name_rest::binary>> -> star_match(rest, name_rest)
        <<>> -> false
      end
    end
  end

  # Collapse consecutive leading stars into one (they're redundant).
  defp skip_stars(<<"*"::utf8, rest::binary>>), do: skip_stars(rest)
  defp skip_stars(seg), do: seg
end
