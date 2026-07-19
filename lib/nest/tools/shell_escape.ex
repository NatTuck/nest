defmodule Nest.Tools.ShellEscape do
  @moduledoc """
  Single-quote escape a string for safe inclusion in a POSIX
  shell command.

  Wraps `path` in single quotes and escapes embedded `'` by
  ending the quote, adding an escaped quote, and resuming the
  quote — the standard portable shell-quoting idiom. Used by
  the `read_file`, `write_file`, and `edit` tools when they
  build `cat '<path>'` commands.
  """

  @doc """
  Single-quote-escape `path`.

      iex> Nest.Tools.ShellEscape.escape("simple")
      "'simple'"

      iex> Nest.Tools.ShellEscape.escape("o'malley")
      "'o'\\''malley'"
  """
  @spec escape(String.t()) :: String.t()
  def escape(path) when is_binary(path) do
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end
