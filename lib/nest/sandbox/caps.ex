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

  `"net"` is the *space's* value by the time a caps map is validated — injected
  by `Nest.Sandbox.with_network_access/2`, which is why a mode's own `"net"` key
  is dead data (`Nest.Spaces.Space`).

  `"shell"` and `"sandbox"` are optional. `"shell"`'s absence means the default
  background-job ceiling (see `Nest.Sandbox.ShellJobs`); `"sandbox"` carries the
  project's declared docker image packages (`Nest.ProjectConfig`), which no cap
  check enforces but which must have the right shape before the docker backend
  builds an image from them.
  """

  @doc "Validates a caps map. Returns `:ok` or `{:error, reason}`."
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(%{"net" => net, "fs" => %{"read" => read, "write" => write}} = caps)
      when is_boolean(net) and is_list(read) and is_list(write) do
    cond do
      "/" not in read ->
        {:error, "caps.fs.read must include \"/\" (the sandbox needs /bin/sh)"}

      not Enum.all?(read, &is_binary/1) ->
        {:error, "caps.fs.read entries must be strings"}

      not Enum.all?(write, &is_binary/1) ->
        {:error, "caps.fs.write entries must be strings"}

      true ->
        with :ok <- validate_shell(caps), do: validate_sandbox(caps)
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

  # Optional capability: the project's declared docker image packages. The list
  # itself is validated where `.nest` is parsed; this is the shape check for a
  # caps map that reached a backend some other way.
  defp validate_sandbox(%{"sandbox" => sandbox}) when not is_map(sandbox),
    do: {:error, "caps.sandbox must be a map"}

  defp validate_sandbox(%{"sandbox" => %{"packages" => packages}})
       when not is_list(packages),
       do: {:error, "caps.sandbox.packages must be a list"}

  defp validate_sandbox(%{"sandbox" => %{"packages" => packages}}) do
    if Enum.all?(packages, &is_binary/1) do
      :ok
    else
      {:error, "caps.sandbox.packages entries must be strings"}
    end
  end

  defp validate_sandbox(_caps), do: :ok
end
