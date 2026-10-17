defmodule Nest.Sandbox.ShellJobs.JobLog do
  @moduledoc """
  A background job's log file, on whichever backend the job ran on.

  The log is written *where the job runs*. Under every backend whose environment
  is the host that is an ordinary file under the agent's scratch directory, and
  `Nest.Sandbox.ShellJobs` appends to it as the output streams in. Under
  `"docker"` it is a file in the container, which nothing on the host can write:
  the command itself writes it (`Nest.Sandbox.Backend.Docker.job_spec/4`), and
  this module reads and removes it *through* the container.

  `Nest.Sandbox.Mounts.host_scratch?/1` is the whole distinction, and the paths
  are the same strings either way — `Mounts.scratch/1` is a host path under one
  backend and a container path under the other — so a job record does not have
  to know which of the two it holds.

  The one cost of the docker branch is that a read is a `docker exec` rather
  than a `File.read`. It is proportional to the log's size either way (logs are
  not capped on disk, by design), and it is the manager's only such call; see
  `Nest.Sandbox.ShellJobs`'s "Blocking" section.

  Every function takes the same `:runner` option as
  `Nest.Sandbox.Backend.Docker.ensure_container/3` — the injectable seam, so the
  docker branch is testable without a daemon.
  """

  alias Nest.Sandbox.Backend.Docker
  alias Nest.Sandbox.Mounts

  @doc """
  Make the log exist and be empty, so a reader never sees a missing file.

  A no-op under `"docker"`: the file is the container's, and the command that
  writes it makes its directory (`Nest.Sandbox.Backend.Docker`).
  """
  @spec prepare(Mounts.t(), String.t()) :: :ok | {:error, term()}
  def prepare(%Mounts{} = mounts, path) do
    if Mounts.host_scratch?(mounts) do
      with :ok <- path |> Path.dirname() |> File.mkdir_p(), do: File.write(path, "")
    else
      :ok
    end
  end

  @doc """
  Append `data` to the log.

  A no-op under `"docker"`: the command's own `tee` has already written those
  bytes, and the copy the manager receives on the exec's stream is the same
  output.
  """
  @spec append(Mounts.t(), String.t(), iodata()) :: :ok | {:error, term()}
  def append(%Mounts{} = mounts, path, data) do
    if Mounts.host_scratch?(mounts), do: File.write(path, data, [:append]), else: :ok
  end

  @doc """
  The log's contents, or `""` when it cannot be read — a job whose log is gone,
  or a container that is no longer there.
  """
  @spec read(Mounts.t(), String.t(), keyword()) :: binary()
  def read(%Mounts{} = mounts, path, opts \\ []) do
    if Mounts.host_scratch?(mounts) do
      case File.read(path) do
        {:ok, content} -> content
        {:error, _reason} -> ""
      end
    else
      case exec(mounts, ["cat", path], opts) do
        {output, 0} -> output
        {_output, _code} -> ""
      end
    end
  end

  @doc """
  Remove the log. A no-op under `"docker"` when the container is gone, which is
  also when the file is.
  """
  @spec remove(Mounts.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def remove(%Mounts{} = mounts, path, opts \\ []) do
    if Mounts.host_scratch?(mounts) do
      File.rm(path)
    else
      exec(mounts, ["rm", "-f", path], opts)
      :ok
    end
  end

  # The container is named after the space, so the name is the same before and
  # after a layout change and this always reaches the container the job's agent
  # is using. `Docker.run/2` goes through the configured runner, so the suite
  # still never talks to a daemon; `opts` is that runner, for the tests.
  defp exec(mounts, tail, opts) do
    case Docker.container_name(mounts) do
      {:ok, name} -> Docker.run(["exec", name | tail], opts)
      {:error, _reason} -> {"", 1}
    end
  end
end
