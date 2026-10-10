defmodule Nest.Sandbox.Failure do
  @moduledoc """
  Classification and operator logging for failures of commands run inside
  bwrap by `Nest.Sandbox`.

  A failed `read`/`stat`/`glob` is classified from bwrap's stderr rather than by
  inspecting the host: the host's view is not the sandbox's view (a masked
  `.nest` is a char device inside but a plain file on the host). bwrap's own
  diagnostics reuse the errno strings (`bwrap: Can't find source path …: No
  such file or directory`), so the bwrap markers are matched first.

  Shared by the executors in `Nest.Sandbox` and the glob runner in
  `Nest.Sandbox.Glob`.
  """

  require Logger

  # Ordered: the bwrap setup-failure markers first, because bwrap reuses the
  # errno text for its own diagnostics.
  @markers [
    {"bwrap:", :sandbox_setup_failed},
    {"Can't ", :sandbox_setup_failed},
    {"Command timed out", :read_timeout},
    {"Command cancelled", :read_cancelled},
    {"Permission denied", :read_permission_denied},
    {"No such file or directory", :enoent},
    {"Not a directory", :enoent},
    {"Is a directory", :eisdir}
  ]

  @doc """
  Map bwrap stderr to an error atom. Falls back to `:read_failed`.
  """
  @spec classify(String.t()) :: atom()
  def classify(stderr) do
    Enum.find_value(@markers, :read_failed, fn {needle, reason} ->
      if String.contains?(stderr, needle), do: reason
    end)
  end

  @doc """
  Log genuinely unexpected failures so a failed read is never silent for the
  operator.

  A missing file, a directory passed to a file read, a permission denial, or a
  cancellation is an ordinary tool outcome (already surfaced to the caller), so
  those stay quiet. A broken sandbox, a timeout, or an unrecognised error is
  logged.
  """
  @spec log(atom(), String.t(), atom(), String.t()) :: :ok
  def log(op, path, reason, stderr)
      when reason in [:read_failed, :sandbox_setup_failed, :read_timeout] do
    Logger.warning("Nest.Sandbox.#{op}: #{reason} for #{path}: #{inspect(stderr)}")
  end

  def log(_op, _path, _reason, _stderr), do: :ok
end
