defmodule Nest.DotConfig.Writer do
  @moduledoc """
  Serializes the configured `Nest.DotConfig.Provider` structs back to TOML
  and writes them to `local.toml` (the in-app editable overlay). `config.toml`
  is never written by the app.

  The written file is the full provider set the user manages; on load,
  `local.toml`'s `providers` table is authoritative over `config.toml`.
  """

  alias Nest.DotConfig
  alias Nest.DotConfig.Model
  alias Nest.DotConfig.Provider

  @doc """
  Write the given provider structs to `local.toml`. Returns `:ok` on
  success or `{:error, reason}` on failure.
  """
  @spec save_providers([Provider.t()]) :: :ok | {:error, term()}
  def save_providers(providers) do
    save_providers(providers, DotConfig.local_file())
  end

  @doc """
  Write the given provider structs to a specific file (test seam).
  """
  @spec save_providers([Provider.t()], String.t()) :: :ok | {:error, term()}
  def save_providers(providers, file) do
    config = %{
      "providers" => Map.new(providers, fn p -> {p.name, provider_to_map(p)} end)
    }

    with {:ok, toml} <- TomlElixir.encode(config) do
      write_atomic(file, toml)
    end
  end

  @doc """
  Write `contents` to `path` atomically: the bytes go to a
  uniquely-named sibling temp file first, then a rename puts them in
  place. A reader therefore sees either the previous contents or the
  complete new ones, never a half-written file, and a crash mid-write
  leaves the old file intact.

  The temp name carries a per-VM counter *and* four random bytes, so
  two writers collide neither within one BEAM nor across two. The temp
  file is created `0600`: a rename replaces the target's mode with the
  new file's, so without this an existing `0600` file would come back
  with the umask's mode.

  Missing parent directories are created. On any failure the temp file
  is removed and `{:error, reason}` is returned.

  A successful write also drops any cached parse of `path`
  (`Nest.DotConfig.invalidate_cache/1`): the bytes under that path are new,
  and the parse cache's identity key cannot see a replacement that keeps the
  file's length and lands inside the cached mtime's second.
  """
  @spec write_atomic(String.t(), iodata()) :: :ok | {:error, term()}
  def write_atomic(path, contents) do
    tmp = tmp_path(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, contents),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      DotConfig.invalidate_cache(path)
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end

  @doc false
  # The temp path `write_atomic/2` writes to, public only so its naming
  # scheme is testable: `<path>.tmp.<counter>.<8 random hex bytes>`. The
  # counter keeps two writers in one VM apart; the random bytes keep two
  # BEAMs -- whose counters start from the same value -- apart.
  @spec tmp_path(String.t()) :: String.t()
  def tmp_path(path) do
    suffix =
      Integer.to_string(System.unique_integer([:positive])) <>
        "." <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    path <> ".tmp." <> suffix
  end

  defp provider_to_map(%Provider{} = p) do
    Map.put(provider_settings_to_map(p), "models", Enum.map(p.models || [], &model_to_map/1))
  end

  defp provider_settings_to_map(%Provider{} = p) do
    %{}
    |> maybe_put("base-url", p.base_url)
    |> maybe_put("api-key", p.api_key)
    |> maybe_put("protocol", p.protocol)
    |> maybe_put("auto-models", p.auto_models)
    |> maybe_put("tags", p.tags)
    |> maybe_put("timeout", p.timeout_seconds)
    |> maybe_put("default-context-limit", p.default_context_limit)
    |> maybe_put("default-thinking-effort", effort_to_string(p.default_thinking_effort))
    |> maybe_put("probe-base-url", p.probe_base_url)
    |> maybe_put("auto-probe", p.auto_probe)
    |> maybe_put("expose-models", p.expose_models)
    |> maybe_put("probe-multimodal", p.probe_multimodal)
  end

  defp model_to_map(%Model{} = m) do
    %{"name" => m.name}
    |> maybe_put("context-limit", m.context_limit)
    |> maybe_put("multi-modal", m.multi_modal)
    |> maybe_put("thinking-effort", effort_to_string(m.thinking_effort))
  end

  defp effort_to_string(nil), do: nil
  defp effort_to_string(effort), do: Atom.to_string(effort)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
