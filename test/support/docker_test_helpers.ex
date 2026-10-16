defmodule Nest.Sandbox.Backend.DockerTestHelpers do
  @moduledoc """
  Fixtures for the docker backend's tests, and the fake daemon they run against.

  Shared by `Nest.Sandbox.Backend.DockerTest` (what the backend decides) and
  `Nest.Sandbox.Backend.DockerLifecycleTest` (what it asks the daemon to do), so
  the two agree on the caps they build and on how a call is recorded.
  """

  alias Nest.Sandbox.Mounts

  @space_id 7
  @calls {__MODULE__, :docker_calls}

  @doc "The space these fixtures belong to."
  def space_id, do: @space_id

  @doc """
  A `Mounts` value for a `"docker"` call in this space.
  """
  def mounts(workspace \\ nil, scratch \\ nil) do
    Mounts.new(workspace, scratch, "docker", @space_id)
  end

  @doc """
  A scratch directory with the real shape (`<space_dir>/<agent>`), so
  `Nest.Sandbox.Paths.scratch_root/1` derives the space dir rather than refusing
  it. A fresh one per call, so a test that means "the same layout" has to bind
  it once.
  """
  def scratch do
    Path.join([
      "/tmp",
      "nest-docker-test-#{System.unique_integer([:positive])}",
      "space-#{@space_id}",
      "agent-a"
    ])
  end

  @doc """
  Caps for a docker mode: the network and the two symbolic writes by default.
  """
  def caps(opts \\ []) do
    %{
      "net" => Keyword.get(opts, :net, false),
      "fs" => %{
        "read" => ["/"],
        "write" => Keyword.get(opts, :write, ["/tmp", ":workspace"])
      }
    }
  end

  @doc "Caps with extra `fs` keys merged in (project mounts, protected paths)."
  def caps_with(extra), do: Map.put(caps(), "fs", Map.merge(caps()["fs"], extra))

  @doc "Caps carrying a project's declared docker packages."
  def caps_with_packages(packages), do: Map.put(caps(), "sandbox", %{"packages" => packages})

  @doc """
  A runner answering from a map of argv prefixes, recording every call.

  Every runner call in these tests is synchronous and from the test process, so
  the process dictionary is the whole record of what the daemon was asked to do —
  which is the observable these tests assert on.
  """
  def scripted_runner(answers) do
    Process.put(@calls, [])

    fn argv ->
      Process.put(@calls, [argv | Process.get(@calls, [])])

      key = Enum.find(Map.keys(answers), :default, &List.starts_with?(argv, &1))
      Map.get(answers, key, {"", 0})
    end
  end

  @doc """
  A runner whose answer may depend on how many calls came before it, for the
  races (a `run`/`build` refused because someone else got there first).
  """
  def sequenced_runner(fun) do
    Process.put(@calls, [])

    fn argv ->
      seen = Process.get(@calls, [])
      Process.put(@calls, [argv | seen])
      fun.(argv, length(seen) + 1)
    end
  end

  @doc "Every argv the runner was asked for, oldest first."
  def calls, do: Enum.reverse(Process.get(@calls, []))

  @doc "The argv of the first recorded call matching `prefix`."
  def call_with(prefix), do: Enum.find(calls(), &List.starts_with?(&1, prefix))
end
