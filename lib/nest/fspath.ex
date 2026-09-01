defmodule Nest.FSPath do
  @moduledoc """
  Pure filesystem-path helpers shared by the sandbox rule helpers.

  These are the single source of truth for path canonicalization and
  containment so that the read-only host fast-path in `Nest.Sandbox`
  authorizes *exactly* the same paths the bwrap bind mounts expose:
  both sides derive from the same `canonical/1` + `under?/2`
  primitives.

  ## Canonicalization

  `canonical/1` resolves symlinks via the `realpath` binary. If the
  path does not exist (or `realpath` is unavailable), it returns the
  path unchanged. Falling back to the literal path is deliberate: a
  write to a path whose parent doesn't exist must fail in the sandbox
  rather than be silently bound-and-created, and non-existent
  `fs.write` entries surface as bwrap "source not found" failures.

  These helpers intentionally avoid touching the filesystem except
  for the single `realpath` call in `canonical/1`.
  """

  @doc """
  Resolve symlinks in `path` via `realpath`, falling back to the
  literal path when it cannot be resolved (missing parent, missing
  `realpath` binary, or other errors).
  """
  @spec canonical(String.t()) :: String.t()
  def canonical(path) when is_binary(path) do
    case System.cmd("realpath", [path], stderr_to_stdout: true) do
      {output, 0} when output != "" -> String.trim_trailing(output)
      _ -> path
    end
  end

  @doc """
  True when `path` is `root` or lies beneath `root` (a directory
  boundary). `/` contains everything.
  """
  @spec under?(String.t(), String.t()) :: boolean()
  def under?(root, path) do
    root == "/" or path == root or String.starts_with?(path, root <> "/")
  end

  @doc """
  Resolve a tool path against the workspace root, mirroring the
  policy used across the file tools: absolute paths are used as-is,
  relative paths are joined onto `workspace`. Returns
  `{:ok, full_path}` or `{:error, message}` when a relative path has
  no workspace to resolve against.
  """
  @spec resolve(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(path, workspace) do
    cond do
      Path.type(path) == :absolute -> {:ok, path}
      is_nil(workspace) -> {:error, "No workspace configured for this agent"}
      true -> {:ok, Path.join(workspace, path)}
    end
  end
end
