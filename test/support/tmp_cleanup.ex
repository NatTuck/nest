defmodule Nest.Test.TmpCleanup do
  @moduledoc """
  Guarded cleanup of test temp paths.

  `SMELLS.md` ("Temp files") requires that cleanup of a temp directory with
  "rm -rf" or similar be guarded by a check that the path contains its
  identifying string. `rm_tmp!/2` centralises that check: it refuses (raising
  `ArgumentError`) unless the path contains the caller's marker, so a typo or a
  bad path join can never delete a real path — only the fixture's own temp path,
  which by construction contains the marker.

  The marker is required and must be non-empty. A path-only API would need a
  default, and no default is safe: `"nest"` appears in ordinary repo paths like
  `test/nest/...`, and the fixtures split between `_build/tmp/...` and
  `System.tmp_dir!()`, so a single default cannot cover them without being
  dangerously loose.
  """

  @doc """
  Removes `path` iff it contains `marker`; otherwise raises `ArgumentError`.

  `marker` is the fixture's own identifying name fragment (e.g.
  `"nest_tools_test_"`), which is also part of the path by construction.
  """
  @spec rm_tmp!(Path.t(), String.t()) :: :ok
  def rm_tmp!(path, marker) when is_binary(path) and is_binary(marker) do
    cond do
      marker == "" ->
        raise ArgumentError, "rm_tmp!/2 requires a non-empty identifying marker"

      not String.contains?(path, marker) ->
        raise ArgumentError,
              "refusing to rm_rf #{inspect(path)}: it does not contain the " <>
                "expected temp marker #{inspect(marker)}"

      true ->
        File.rm_rf!(path)
        :ok
    end
  end
end
