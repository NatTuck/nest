defmodule Nest.Sandbox.Caps do
  @moduledoc """
  Validation for the sandbox capability (`caps`) map.

  Extracted from `Nest.Sandbox` to keep that module under the size cap.
  A caps map matches the JSONB shape stored on `Vocation.modes`:

      %{
        "net" => boolean(),
        "fs" => %{"read" => [String.t()], "write" => [String.t()]},
        "shell" => %{"background" => non_neg_integer()}
      }

  `"shell"` is optional; its absence means the default background-job
  ceiling (see `Nest.Sandbox.ShellJobs`).
  """

  @doc "Validates a caps map. Returns `:ok` or `{:error, reason}`."
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{"net" => net, "fs" => %{"read" => read, "write" => write}} = caps)
      when is_boolean(net) and is_list(read) and is_list(write) do
    cond do
      "/" not in read ->
        {:error, "caps.fs.read must include \"/\" (bwrap needs /bin/sh)"}

      not Enum.all?(read, &is_binary/1) ->
        {:error, "caps.fs.read entries must be strings"}

      not Enum.all?(write, &is_binary/1) ->
        {:error, "caps.fs.write entries must be strings"}

      true ->
        validate_shell(caps)
    end
  end

  def validate(%{"net" => _, "fs" => %{"read" => _, "write" => write}})
      when not is_list(write),
      do: {:error, "caps.fs.write must be a list"}

  def validate(%{"net" => _, "fs" => %{"read" => read, "write" => _}})
      when not is_list(read),
      do: {:error, "caps.fs.read must be a list"}

  def validate(%{"net" => _, "fs" => %{"read" => _}}),
    do: {:error, "caps.fs.write must be a list"}

  def validate(%{"net" => _, "fs" => %{"write" => _}}),
    do: {:error, "caps.fs.read must be a list"}

  def validate(%{"net" => _, "fs" => _}),
    do: {:error, "caps.fs must be a map with \"read\" (list) and \"write\" (list) keys"}

  def validate(%{"net" => _}), do: {:error, "caps.fs is required"}
  def validate(%{"fs" => _}), do: {:error, "caps.net is required"}
  def validate(caps), do: {:error, "invalid caps: #{inspect(caps)}"}

  # Optional capability: the per-agent ceiling on concurrent background
  # shell jobs. Absence means the default (see `Nest.Sandbox.ShellJobs`).
  defp validate_shell(%{"shell" => shell}) when not is_map(shell),
    do: {:error, "caps.shell must be a map"}

  defp validate_shell(%{"shell" => %{"background" => n}})
       when not (is_integer(n) and n >= 0),
       do: {:error, "caps.shell.background must be a non-negative integer"}

  defp validate_shell(_caps), do: :ok
end
