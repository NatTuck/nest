defmodule Nest.DotConfig.Writer do
  @moduledoc """
  Serializes the configured `Nest.DotConfig.Provider` structs back to TOML
  and writes them to `local.toml` (the in-app editable overlay). `config.toml`
  is never written by the app.

  The written file is the full provider set the user manages, **plus** a
  `deleted-providers` list naming the providers that set no longer contains, so
  `Nest.DotConfig.load/0`'s merge does not bring them back from `config.toml`.
  A provider the user re-adds is removed from that list in the same write, which
  is what makes re-adding work.

  The list is computed from what the files say, not from the payload alone: a
  name is recorded as deleted when `config.toml` defines it and the payload does
  not, or when the file already recorded it and the payload still does not. A
  provider that only ever lived in `local.toml` needs no record — it is simply
  absent from the file that replaces it — and must not get one, or a name the
  operator later adds to `config.toml` by hand would be invisible for a reason
  nothing on screen explains.

  Writing stops with `{:error, reason}` when the files that answer those two
  questions cannot be read: the record would otherwise be a guess, and a wrong
  guess either resurrects a deleted provider or hides a live one.
  """

  alias Nest.DotConfig
  alias Nest.DotConfig.Model
  alias Nest.DotConfig.Provider

  @doc """
  Write the given provider structs to `local.toml`. Returns `:ok` on
  success or `{:error, reason}` on failure.
  """
  @spec save_providers([Provider.t()]) :: :ok | {:error, String.t()}
  def save_providers(providers) do
    save_providers(providers, DotConfig.local_file())
  end

  @doc """
  Write the given provider structs to a specific file (test seam).

  Every failure is `{:error, sentence}`: a refusal says which file it could not
  read, and a write that does not land names the file and the filesystem's
  reason. `NestWeb.LobbyChannel.Providers` hands that sentence to the operator,
  so a refused save says why instead of only `failed_to_save`.
  """
  @spec save_providers([Provider.t()], String.t()) :: :ok | {:error, String.t()}
  def save_providers(providers, file) do
    with {:ok, deleted} <- deleted_providers(file, MapSet.new(providers, & &1.name)),
         {:ok, toml} <- TomlElixir.encode(contents(providers, deleted)) do
      case write_atomic(file, toml) do
        :ok -> :ok
        {:error, reason} -> {:error, "could not write #{file}: #{inspect(reason)}"}
      end
    end
  end

  defp contents(providers, deleted) do
    %{"providers" => Map.new(providers, fn p -> {p.name, provider_to_map(p)} end)}
    |> maybe_put("deleted-providers", deleted)
  end

  # The names this write records as deleted:
  #
  #   * a provider `config.toml` defines that the payload does not — the user
  #     deleted it, and without a record the next load re-adds it;
  #   * a name the file already recorded that the payload still does not
  #     contain — the deletion outlives every write until the provider is added
  #     back;
  #
  # and a name in the payload is cleared from both, which is what makes
  # re-adding a deleted provider work.
  #
  # A record naming a provider that exists nowhere is **kept**, not pruned.
  # Pruning would only happen on a write, so whether such a name came back would
  # depend on whether a save happened to land in between; and a deletion is the
  # user's decision, which a later edit to `config.toml` must not quietly undo.
  # To bring the name back, add it in the app (which clears the record) or
  # remove it from `deleted-providers` by hand.
  defp deleted_providers(file, written_names) do
    with {:ok, base_names} <- base_provider_names(),
         {:ok, previous} <- previous_deleted_providers(file) do
      kept =
        base_names
        |> MapSet.union(previous)
        |> MapSet.difference(written_names)
        |> Enum.sort()

      {:ok, empty_list_as_nil(kept)}
    end
  end

  # `nil` is how `contents/2` says "omit the key", so a write that deletes
  # nothing leaves the file exactly as it was before this feature existed.
  defp empty_list_as_nil([]), do: nil
  defp empty_list_as_nil(list), do: list

  # The names `config.toml` defines. Those are the only providers a deletion has
  # to be recorded against, because `local.toml` is rewritten wholesale by this
  # module: a name that only ever lived there is gone from the new file already.
  #
  # A missing `config.toml` defines no providers, which is a fact and not a
  # guess; a `config.toml` that cannot be read or parsed is neither, so the
  # write stops rather than recording a record it cannot stand behind.
  defp base_provider_names do
    path = DotConfig.config_file()

    if File.exists?(path) do
      case DotConfig.load(path) do
        {:ok, config} -> {:ok, MapSet.new(Map.keys(config.providers))}
        {:error, reason} -> {:error, "cannot read #{path} to record deleted providers: #{reason}"}
      end
    else
      {:ok, MapSet.new()}
    end
  end

  # The records the file already carries, so a deletion is remembered across
  # writes and a re-added name can be cleared from it.
  defp previous_deleted_providers(file) do
    if File.exists?(file) do
      case DotConfig.load(file) do
        {:ok, config} ->
          {:ok, MapSet.new(config.deleted_providers)}

        {:error, reason} ->
          {:error, "cannot read #{file} to keep its deleted providers: #{reason}"}
      end
    else
      {:ok, MapSet.new()}
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
  """
  @spec write_atomic(String.t(), iodata()) :: :ok | {:error, term()}
  def write_atomic(path, contents) do
    tmp = tmp_path(path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, contents),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
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
    |> maybe_put("first_byte_timeout", p.first_byte_timeout_seconds)
    |> maybe_put("stream_idle_timeout", p.stream_idle_timeout_seconds)
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
