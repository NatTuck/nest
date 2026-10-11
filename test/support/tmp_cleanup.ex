defmodule Nest.Test.TmpCleanup do
  @moduledoc """
  Guarded cleanup of test temp paths.

  `SMELLS.md` ("Temp files") requires that cleanup of a temp directory with
  "rm -rf" or similar be guarded by a check that the path contains its
  identifying string. `rm_tmp!/2` centralises that check and adds a second,
  independent one: the path must also live under a permitted temp root (the OS
  temp dir, or the project-relative `_build/tmp`). A typo or a bad path join
  therefore cannot delete a real path even if the marker is sloppy — only the
  fixture's own temp path, which by construction both contains the marker and
  sits under a temp root.

  The marker is required and must be non-empty. A path-only API would need a
  default, and no default is safe: `"nest"` appears in ordinary repo paths like
  `test/nest/...`, and the fixtures split between `_build/tmp/...` and
  `System.tmp_dir!()`, so a single default cannot cover them without being
  dangerously loose.
  """

  @doc """
  Removes `path` iff it contains `marker` and sits under a permitted temp root;
  otherwise raises `ArgumentError`.

  `marker` is the fixture's own identifying name fragment (e.g.
  `"nest_tools_test_"`), which is also part of the path by construction.
  """
  @spec rm_tmp!(String.t(), String.t()) :: :ok
  def rm_tmp!(path, marker) when is_binary(path) and is_binary(marker) do
    cond do
      marker == "" ->
        raise ArgumentError, "rm_tmp!/2 requires a non-empty identifying marker"

      not String.contains?(path, marker) ->
        raise ArgumentError,
              "refusing to rm_rf #{inspect(path)}: it does not contain the " <>
                "expected temp marker #{inspect(marker)}"

      not temp_path?(path) ->
        raise ArgumentError,
              "refusing to rm_rf #{inspect(path)}: it is not under a permitted temp root"

      true ->
        File.rm_rf!(path)
        :ok
    end
  end

  # The only two roots the suite builds temp paths under: the OS temp dir
  # (`/tmp/...`) and the project-relative `_build/tmp` (gitignored).
  defp temp_roots do
    [System.tmp_dir!(), Path.join([File.cwd!(), "_build", "tmp"])]
  end

  defp temp_path?(path) do
    expanded = Path.expand(path)

    Enum.any?(temp_roots(), fn root ->
      String.starts_with?(expanded, Path.expand(root) <> "/")
    end)
  end
end
