defmodule Nest.ProjectConfig do
  @moduledoc """
  Per-project sandbox configuration loaded from `<project>/.nest`.

  A project may drop a `.nest` file in its root to grant the sandbox
  extra filesystem access it needs to build/test. The file is TOML:

      [[mount]]
      path   = "~/.local/data/inkfish/uploads/test"
      mode   = "rw" # "rw" | "tmp"
      create = true      # default false

      [shell]
      background = 3     # max concurrent background shell jobs per agent

  Each `[[mount]]` entry declares a `path` (absolute, `~`-expanded, or
  relative to the project root) and a `mode`:

    * `"rw"` — bind the host path read-write at its own path.
    * `"tmp"` — bind a directory under the agent's per-agent `/tmp`
      scratch at `path`. Writes never touch the host; the backing
      directory persists for the agent's lifetime (and is visible
      inside the sandbox under `/tmp/project/<slug>`).

  `create = true` makes Nest `mkdir_p` the path before mounting, so a
  project can declare a scratch path whose parents don't exist yet.

  The optional `[shell]` table raises the per-agent ceiling on
  concurrent background shell jobs (`shell-cmd` with `background: true`;
  see `Nest.Sandbox.ShellJobs`). It defaults to 1, and 0 disables
  background jobs.

  ## Gating

  Project mounts are merged into a mode's caps **only when that mode
  already writes the symbolic `":workspace"`** — a read-only mode must
  stay read-only. In those modes the `.nest` file itself is mounted
  read-only (see `Nest.Sandbox`), so an agent can never edit its own
  sandbox. When `.nest` is absent, a read-only `/dev/null` is masked
  over the path so an agent can't create one either.

  ## Failures

  A malformed `.nest` never degrades silently: `load/1` logs an error,
  `apply_or_default/3` leaves the mode's caps unchanged, and
  `section/1` renders a visible error block into the system prompt.
  """

  require Logger

  alias Nest.FSPath

  @file_name ".nest"
  @modes ~w(rw tmp)

  @typedoc "A project mount with its host path expanded."
  @type mount :: map()

  @typedoc "The `[shell]` sandbox settings from `.nest`."
  @type shell :: %{optional(String.t()) => non_neg_integer()}

  @typedoc "The parsed `.nest` file: mounts plus optional `[shell]` settings."
  @type config :: %{optional(String.t()) => [mount()] | shell() | nil}

  @doc """
  Load and parse `<workspace>/.nest`, cached by `{path, mtime}`.

  Returns `{:ok, config}` (`%{"mounts" => []}` when there is no file)
  or `{:error, reason}` when the file exists but is malformed.
  """
  @spec load(String.t() | nil) :: {:ok, config()} | {:error, String.t()}
  def load(workspace) when is_binary(workspace) do
    path = Path.join(workspace, @file_name)

    case cached(path) do
      {:ok, result} ->
        result

      :miss ->
        result = compute(workspace, path)
        cache(path, result)
        result
    end
  end

  def load(nil), do: {:ok, %{"mounts" => []}}

  # Read + parse + validate, logging a malformed file exactly once per
  # mtime (the result is cached, so `load/1` doesn't re-log).
  defp compute(workspace, path) do
    result =
      case File.read(path) do
        {:ok, content} -> parse(content, workspace)
        {:error, :enoent} -> {:ok, %{"mounts" => []}}
        {:error, reason} -> {:error, "could not read .nest: #{inspect(reason)}"}
      end

    case result do
      {:error, reason} -> Logger.error("Nest.ProjectConfig: ignoring #{path}: #{reason}")
      _ -> :ok
    end

    result
  end

  defp parse(content, workspace) do
    case Toml.decode(content) do
      {:ok, raw} -> validate(raw, workspace)
      {:error, reason} -> {:error, "invalid TOML: #{inspect(reason)}"}
    end
  end

  defp validate(raw, workspace) do
    with {:ok, mounts} <- validate_mounts(Map.get(raw, "mount", []), workspace),
         :ok <- reject_duplicates(mounts),
         {:ok, shell} <- validate_shell(Map.get(raw, "shell")) do
      config = %{"mounts" => mounts}
      {:ok, if(shell, do: Map.put(config, "shell", shell), else: config)}
    end
  end

  defp validate_shell(nil), do: {:ok, nil}

  defp validate_shell(raw) when is_map(raw) do
    case Map.get(raw, "background", 1) do
      n when is_integer(n) and n >= 0 -> {:ok, %{"background" => n}}
      _ -> {:error, "shell background must be a non-negative integer"}
    end
  end

  defp validate_shell(_raw), do: {:error, "shell must be a table"}

  defp validate_mounts(mounts, workspace) when is_list(mounts) do
    ws = FSPath.canonical(workspace)

    mounts
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case validate_mount(entry, ws) do
        {:ok, mount} -> {:cont, {:ok, [mount | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  defp validate_mounts(_mounts, _workspace), do: {:error, "mount must be an array of tables"}

  defp validate_mount(entry, ws) when is_map(entry) do
    with {:ok, raw_path} <- fetch_string(entry, "path"),
         {:ok, mode} <- fetch_mode(entry),
         {:ok, create} <- fetch_create(entry),
         {:ok, dest} <- expand_dest(raw_path, ws) do
      {:ok, %{"dest" => dest, "mode" => mode, "create" => create}}
    end
  end

  defp validate_mount(_entry, _ws), do: {:error, "each [[mount]] must be a table"}

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "mount #{key} must be a non-empty string"}
    end
  end

  defp fetch_mode(map) do
    case Map.get(map, "mode") do
      mode when mode in @modes -> {:ok, mode}
      _ -> {:error, "mount mode must be one of: rw, tmp"}
    end
  end

  defp fetch_create(map) do
    case Map.get(map, "create", false) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "mount create must be a boolean"}
    end
  end

  # Expand a mount path (`~`-aware, relative to the project root),
  # resolve symlinks. The filesystem root is rejected: binding it read-write would defeat the sandbox.
  defp expand_dest(raw, ws) do
    dest = raw |> Path.expand(ws) |> FSPath.canonical()

    if dest == "/" do
      {:error, "mount path must not be /"}
    else
      {:ok, dest}
    end
  end

  defp reject_duplicates(mounts) do
    dests = Enum.map(mounts, & &1["dest"])

    if length(dests) == length(Enum.uniq(dests)) do
      :ok
    else
      {:error, "duplicate mount paths"}
    end
  end

  @doc """
  Merge the project config into `caps`, returning effective caps.

  Only modes that write the symbolic `":workspace"` receive project
  mounts (plus the `.nest` read-only protection); every other mode is
  returned unchanged. Returns `{:error, reason}` when `.nest` is
  malformed.
  """
  @spec effective_caps(map(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def effective_caps(caps, workspace, tmp_path) do
    with {:ok, config} <- load(workspace) do
      {:ok, merge(caps, config, workspace, tmp_path)}
    end
  end

  @doc """
  Like `effective_caps/3` but never fails: a malformed `.nest` leaves `caps`
  unchanged (the mode's default sandbox is in effect). `load/1` logs
  the error.
  """
  @spec apply_or_default(map(), String.t() | nil, String.t() | nil) :: map()
  def apply_or_default(caps, workspace, tmp_path) do
    case effective_caps(caps, workspace, tmp_path) do
      {:ok, merged} -> merged
      {:error, _reason} -> caps
    end
  end

  # Project mounts are additive write capabilities, so they only make
  # sense in modes that can already write the project. Other modes are
  # returned untouched (a read-only mode must stay read-only).
  defp merge(caps, config, workspace, tmp_path) do
    if is_binary(workspace) and workspace_writable?(caps) do
      caps
      |> put_in(["fs", "project"], resolve_mounts(mounts(config), tmp_path))
      |> put_in(["fs", "protected"], protected_entries(workspace))
      |> put_shell(config)
    else
      caps
    end
  end

  # The `[shell]` cap is an additive grant (raising the per-agent
  # background-job ceiling), so it follows the same writable-mode gate
  # as mounts.
  defp put_shell(caps, %{"shell" => %{"background" => n}}) do
    shell = caps |> Map.get("shell", %{}) |> Map.put("background", n)
    Map.put(caps, "shell", shell)
  end

  defp put_shell(caps, _config), do: caps

  defp mounts(%{"mounts" => mounts}), do: mounts
  defp mounts(_config), do: []

  defp shell(%{"shell" => shell}), do: shell
  defp shell(_config), do: nil

  defp workspace_writable?(caps), do: ":workspace" in (get_in(caps, ["fs", "write"]) || [])

  defp resolve_mounts(mounts, tmp_path) do
    Enum.map(mounts, fn mount -> Map.put(mount, "source", source_for(mount, tmp_path)) end)
  end

  defp source_for(%{"mode" => "rw", "dest" => dest}, _tmp_path), do: dest

  defp source_for(%{"mode" => "tmp", "dest" => dest}, tmp_path) when is_binary(tmp_path) do
    Path.join([tmp_path, "project", slug(dest)])
  end

  defp source_for(_mount, _tmp_path), do: nil

  defp slug(dest) do
    :crypto.hash(:sha256, dest) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  # The `.nest` file is always protected (read-only) in a writable
  # workspace. When the file is absent we mask `/dev/null` over the
  # path so an agent can't create one (which would be picked up on the
  # next spawn and grant it extra host access). `read_source/2` maps
  # the mask to `/dev/null` so the host fast-path stays identical to
  # what bwrap exposes.
  defp protected_entries(workspace) do
    nest = Path.join(canonical_ws(workspace), @file_name)
    source = if File.exists?(nest), do: nest, else: "/dev/null"
    [%{"path" => nest, "source" => source}]
  end

  # `FSPath.canonical/1` shells out to `realpath`; cache the result per
  # workspace so per-message caps resolution doesn't spawn a process.
  defp canonical_ws(workspace) do
    key = {:workspace, workspace}

    case :ets.lookup(cache_table(), key) do
      [{_, canonical}] ->
        canonical

      [] ->
        canonical = FSPath.canonical(workspace)
        :ets.insert(cache_table(), {key, canonical})
        canonical
    end
  end

  @doc """
  Map `path` to the host path the read-only fast-path should read so it
  stays byte-identical to what bwrap exposes. A protected path (the
  `.nest` file, or `/dev/null` when masked) maps to its source; a
  project `tmp` mount maps to its backing dir under the agent tmp.
  Everything else reads at its own path.
  """
  @spec read_source(String.t(), map()) :: String.t()
  def read_source(path, caps) do
    canonical = FSPath.canonical(path)

    case mount_for(canonical, caps) do
      nil -> path
      {dest, source} -> source <> String.replace_prefix(canonical, dest, "")
    end
  end

  @doc """
  `mkdir_p` project-mount backing dirs before bwrap runs: `tmp` sources
  must exist to be bind sources, and `create = true` dirs must exist to
  be mount points.
  """
  @spec ensure_dirs(map()) :: :ok
  def ensure_dirs(caps) do
    Enum.each(project_mounts(caps), fn
      %{"mode" => "tmp", "source" => source} when is_binary(source) ->
        File.mkdir_p!(source)

      %{"mode" => "rw", "create" => true, "dest" => dest} ->
        File.mkdir_p!(dest)

      _ ->
        :ok
    end)
  end

  defp mount_for(canonical, caps) do
    case protected_for(canonical, caps) do
      %{"path" => dest, "source" => source} -> {dest, source}
      nil -> shadow_mount(canonical, caps)
    end
  end

  defp protected_for(canonical, caps) do
    Enum.find(protected_paths(caps), fn p -> p["path"] == canonical end)
  end

  defp shadow_mount(canonical, caps) do
    case shadow_for(canonical, caps) do
      %{"dest" => dest, "source" => source} -> {dest, source}
      nil -> nil
    end
  end

  defp shadow_for(canonical, caps) do
    caps
    |> project_mounts()
    |> Enum.filter(&is_binary(&1["source"]))
    |> Enum.find(fn m -> FSPath.under?(m["dest"], canonical) end)
  end

  defp project_mounts(caps), do: get_in(caps, ["fs", "project"]) || []

  defp protected_paths(caps), do: get_in(caps, ["fs", "protected"]) || []

  @doc """
  The system-prompt section describing the project sandbox config, or a
  visible error block when `.nest` is malformed. Returns an empty
  string when there is no `.nest` (or no workspace).
  """
  @spec section(String.t() | nil) :: String.t()
  def section(workspace) do
    case load(workspace) do
      {:ok, config} -> if empty_config?(config), do: "", else: render_section(config)
      {:error, reason} -> error_section(reason)
    end
  end

  defp empty_config?(config), do: mounts(config) == [] and shell(config) == nil

  defp render_section(config) do
    lines = Enum.map(mounts(config), &render_mount/1) ++ shell_lines(config)

    "\n\n[Project sandbox config]\n\n" <>
      "This project has a `.nest` file granting extra sandbox settings " <>
      "(only in modes that can write the project):\n\n" <>
      Enum.join(lines, "\n") <> "\n\nThe `.nest` file itself is mounted read-only.\n"
  end

  defp shell_lines(%{"shell" => %{"background" => n}}) do
    ["- at most #{n} background shell job(s) per agent"]
  end

  defp shell_lines(_config), do: []

  defp render_mount(%{"dest" => dest, "mode" => "rw"}),
    do: "- read-write access to #{dest}"

  defp render_mount(%{"dest" => dest, "mode" => "tmp"}),
    do: "- #{dest} backed by a scratch directory under the agent /tmp"

  defp error_section(reason) do
    "\n\n[Project sandbox config error]\n\n" <>
      ".nest could not be loaded: #{reason}. " <>
      "No project mounts were applied; the mode's default sandbox is in effect.\n"
  end

  # ---- cache (keyed by {path, mtime}, mirroring Nest.DotConfig) ----

  @cache_table :nest_project_config_cache

  defp cached(path) do
    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         [{_, result}] <- :ets.lookup(cache_table(), {path, mtime}) do
      {:ok, result}
    else
      _ -> :miss
    end
  end

  defp cache(path, result) do
    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix) do
      :ets.insert(cache_table(), {{path, mtime}, result})
    end
  end

  defp cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> @cache_table
        end

      _ ->
        @cache_table
    end
  end

  @doc false
  # Test-only: drop the mtime cache so a rewritten `.nest` is re-read
  # even within the same mtime second.
  @spec clear_cache() :: :ok
  def clear_cache do
    :ets.delete_all_objects(cache_table())
    :ok
  end
end
