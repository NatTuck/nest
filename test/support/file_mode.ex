defmodule Nest.Test.FileMode do
  @moduledoc """
  The permission bits of a path, for assertions about the modes Nest creates.

  `File.stat!/1`'s `mode` carries the file-type bits alongside the permission
  bits, so comparing it to `0o755` fails for a directory however it was created.
  One helper rather than a private copy per test file: the assertion is always
  the same one, and it is the observable `Nest.FileModes` and the transcript's
  `umask` preamble are both judged by.
  """

  @doc """
  The permission bits of `path`: `0o755` for a `0755` directory, `0o644` for a
  `0644` file.
  """
  @spec mode(Path.t()) :: non_neg_integer()
  def mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
