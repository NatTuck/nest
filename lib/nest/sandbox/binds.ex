defmodule Nest.Sandbox.Binds do
  @moduledoc """
  The binds one sandbox call makes, as `{source, dest, mode}` triples.

  This is the one derivation of the bind set, shared by the two backends that
  bind anything, so the two cannot drift:

    * `Nest.Sandbox.Backend.Bwrap` renders each triple as `--bind`/`--ro-bind`
      over the host.
    * The docker backend renders the same list twice, because the container and
      the sandbox inside it bind at different layers: `-v source:dest:mode` for
      the container, and a self-bind of `dest` for the bwrap inside it (see
      `Nest.Sandbox.Backend.Docker` for why the container's view is what the
      inner one rebinds).

  The set, in the order it must be applied:

    1. the workspace, at its own path, `rw` iff the mode writes `":workspace"`;
    2. every other `caps.fs.write` path, at its canonical path, `rw`;
    3. the scratch root at `#{Nest.Sandbox.Paths.sandbox_root()}` — the space
       scratch dir under bwrap, the container's own `/tmp` under docker — `rw`
       iff the mode writes `"/tmp"`;
    4. the `.nest` project mounts, `rw`;
    5. the `.nest` read-only mask, `ro`.

  Order is load-bearing: 5 has to come after 1 so the mask wins, and the
  readable roots bwrap binds (`caps.fs.read`) come before all of them.

  `caps` must be a map: every caller has already resolved one
  (`Nest.Sandbox.default_caps/0` is the legacy profile), and a second definition
  of that default here would be a second source of truth.
  """

  alias Nest.FSPath
  alias Nest.ProjectConfig
  alias Nest.Sandbox.{Mounts, Paths}

  @typedoc """
  One bind: `source` is what is bound, `dest` where, and `mode` whether the
  result may be written.
  """
  @type spec :: {String.t(), String.t(), :rw | :ro}

  @doc """
  The binds for `caps` on `mounts`.
  """
  @spec specs(map(), Mounts.t()) :: [spec()]
  def specs(caps, mounts) do
    writes = write_list(caps)

    workspace_bind(Mounts.workspace(mounts), caps) ++
      extra_write_binds(caps, mounts) ++
      scratch_bind(mounts, writes) ++
      project_binds(caps) ++
      protected_binds(caps)
  end

  @doc """
  The mode the workspace is bound with: `:rw` when the mode writes the symbolic
  `":workspace"`, `:ro` otherwise.
  """
  @spec workspace_mode(map()) :: :rw | :ro
  def workspace_mode(caps), do: mode(":workspace" in write_list(caps))

  @doc """
  The binds a *container* makes for a whole space: the superset a space's modes
  can need, as host paths.

  A container's mounts are fixed when it is created, and one container serves
  every mode a space can run, so its binds cannot be the ones a single call's
  caps ask for. They are the binds of a mode that writes the workspace — which
  is exactly the set `.nest` project mounts are granted to
  (`Nest.ProjectConfig.effective_caps/2` gives them only to modes that write
  `":workspace"`, along with the `.nest` mask) — and the sandbox inside the
  container tightens per call. A read-only mode therefore still cannot write the
  workspace or a project mount; it merely sees them, read-only, which is what it
  would see under bwrap too (through bwrap's own read-only root bind).

  The scratch bind is dropped here, and only here: a container binds *host*
  paths, and under a backend whose `/tmp` is the container's own there is
  nothing to bind. The entry exists so the sandbox inside can set `/tmp`'s mode
  with a self-bind, and a container that took it literally would replace its own
  `/tmp` with the host's.
  """
  @spec container_specs(Mounts.t()) :: [spec()]
  def container_specs(mounts) do
    mounts
    |> container_caps()
    |> specs(mounts)
    |> Enum.reject(&container_scratch?/1)
  end

  @doc """
  The `caps.fs.write` entries that name a path no bind step covers.

  A mode may write any path it likes. The two symbolic entries and the `.nest`
  mounts are the ones a bind step covers; every other path is bound at its own
  canonical path (`specs/2`), which a backend that binds the host can do and the
  docker backend cannot: its binds are the container's, and a path the container
  does not have is not a path it can bind. `Nest.Sandbox.Backend.Docker` refuses
  on exactly this list, by name.
  """
  @spec unbound_write_paths(map(), Mounts.t()) :: [String.t()]
  def unbound_write_paths(caps, mounts) do
    bound = already_bound(caps, mounts)

    caps
    |> write_list()
    |> Enum.reject(&(&1 in bound))
  end

  # The caps shape of a mode that writes the workspace and the scratch — what a
  # container has to be able to serve — with the `.nest` project mounts and mask
  # merged in by `Nest.ProjectConfig`, which is the only thing that knows how to
  # read them. A malformed `.nest` leaves the shape alone, exactly as
  # `ProjectConfig.resolve_caps/2` does everywhere else.
  defp container_caps(mounts) do
    caps = %{"net" => false, "fs" => %{"read" => ["/"], "write" => [":workspace", "/tmp"]}}

    case ProjectConfig.effective_caps(caps, mounts) do
      {:ok, merged} -> merged
      {:error, _reason} -> caps
    end
  end

  defp container_scratch?({source, _dest, _mode}), do: source == Paths.sandbox_root()

  # The workspace is bound at its *canonical* path — symlinks resolved — so a
  # workspace reached through a symlink binds to its real target. The path the
  # caller named is not lost: `--chdir` still uses it, and under bwrap the
  # symlink itself is visible through the read-only root bind, so a path the
  # agent was given resolves through it to the writable bind. A backend with no
  # such root bind has to materialize that spelling instead
  # (`Nest.Sandbox.Backend.Docker`).
  defp workspace_bind(workspace, caps) when is_binary(workspace) do
    canonical = FSPath.canonical(workspace)

    [{canonical, canonical, workspace_mode(caps)}]
  end

  defp workspace_bind(_workspace, _caps), do: []

  defp scratch_bind(%Mounts{scratch: nil}, _writes), do: []

  defp scratch_bind(%Mounts{} = mounts, writes) do
    case Mounts.scratch_bind_source(mounts) do
      nil -> []
      source -> [{source, Paths.sandbox_root(), mode("/tmp" in writes)}]
    end
  end

  defp extra_write_binds(caps, mounts) do
    caps
    |> unbound_write_paths(mounts)
    |> Enum.map(&FSPath.canonical/1)
    |> Enum.uniq()
    |> Enum.map(&{&1, &1, :rw})
  end

  # The paths a dedicated step already binds.
  defp already_bound(caps, mounts) do
    workspace = Mounts.workspace(mounts)

    [":workspace", "/tmp"] ++
      if(is_binary(workspace), do: [workspace, FSPath.canonical(workspace)], else: []) ++
      Enum.map(project_list(caps), & &1["dest"]) ++
      Enum.map(protected_list(caps), & &1["path"])
  end

  defp project_binds(caps) do
    caps
    |> project_list()
    |> Enum.filter(&is_binary(&1["source"]))
    |> Enum.map(fn %{"dest" => dest, "source" => source} -> {source, dest, :rw} end)
  end

  defp protected_binds(caps) do
    caps
    |> protected_list()
    |> Enum.flat_map(fn %{"path" => path, "source" => source} -> [{source, path, :ro}] end)
  end

  defp mode(true), do: :rw
  defp mode(false), do: :ro

  defp write_list(caps), do: get_in(caps, ["fs", "write"]) || []
  defp project_list(caps), do: get_in(caps, ["fs", "project"]) || []
  defp protected_list(caps), do: get_in(caps, ["fs", "protected"]) || []
end
