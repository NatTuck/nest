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

  ## The api key

  The browser never receives a provider's key (#202), so it cannot echo one back
  to mean "unchanged". Each provider carries `api_key_source` instead, and the
  key line is merged per provider, from the overlay this write replaces:

    * `:clear` writes `api-key = ""` **explicitly**, so it shadows a key
      `config.toml` defines. Omitting the line would let the base's key through,
      which is not a clear.
    * `:set` writes the value the payload carried.
    * `:keep` writes what the overlay already held — including a `${ENV}` or
      `file:` **reference**, verbatim, never the secret it resolves to — and
      omits the line when the overlay held none. An omitted key is what lets a
      key `config.toml` defines still apply: `Nest.DotConfig.load/0` inherits it
      for an overlay entry that sets none, which is the one field the per-name
      merge does not replace. Writing `""` for "unchanged" would shadow the base
      with nothing.

  A **rename** arrives as `{:renamed_from, name}`: the same provider with nothing
  typed, so its key has to travel with it (#203). That is the one case where a
  keep writes a key the overlay did not hold — the old name's block is being
  tombstoned or dropped, so a key that lives only in `config.toml` under the old
  name is unreachable unless it is carried to the new one.
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

  `file` replaces only the **overlay**: the base a deletion is recorded against
  is still `Nest.DotConfig.config_file/0`, because that is the file the record
  has to hide the provider from. A test that wants a hermetic write therefore
  stubs both.

  Every failure is `{:error, sentence}`: a refusal says which file it could not
  read, and a write that does not land names the file and the filesystem's
  reason. `NestWeb.LobbyChannel.Providers` hands that sentence to the operator,
  so a refused save says why instead of only `failed_to_save`.
  """
  @spec save_providers([Provider.t()], String.t()) :: :ok | {:error, String.t()}
  def save_providers(providers, file) do
    with {:ok, previous} <- previous_local(file),
         {:ok, base} <- base_providers(),
         {:ok, deleted} <- deleted_providers(previous, base, MapSet.new(providers, & &1.name)),
         {:ok, toml} <-
           TomlElixir.encode(contents(with_api_keys(providers, previous, base), deleted)) do
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
  defp deleted_providers(previous, base, written_names) do
    # The **written** names, so a renamed provider leaves its old name behind:
    # recorded when the base defines it (or it would come back beside the
    # rename), simply gone when it does not.
    kept =
      base
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(MapSet.new(previous.deleted))
      |> MapSet.difference(written_names)
      |> Enum.sort()

    {:ok, empty_list_as_nil(kept)}
  end

  # `nil` is how `contents/2` says "omit the key", so a write that deletes
  # nothing leaves the file exactly as it was before this feature existed.
  defp empty_list_as_nil([]), do: nil
  defp empty_list_as_nil(list), do: list

  # What `config.toml` defines. Its names are the only providers a deletion has
  # to be recorded against, because `local.toml` is rewritten wholesale by this
  # module: a name that only ever lived there is gone from the new file already.
  # Its keys are what a rename carries.
  #
  # A missing `config.toml` defines no providers, which is a fact and not a
  # guess; a `config.toml` that cannot be read or parsed is neither, so the
  # write stops rather than recording a record it cannot stand behind.
  defp base_providers do
    path = DotConfig.config_file()

    if File.exists?(path) do
      case load_for_record(path) do
        {:ok, config} -> {:ok, config.providers}
        {:error, reason} -> {:error, "cannot use #{path} to record deleted providers: #{reason}"}
      end
    else
      {:ok, %{}}
    end
  end

  # `DotConfig.load/1` returns a tuple for a file it cannot read or parse, but a
  # *semantic* error raises out of `parse_config/1` — so the rescue is what makes
  # the sentence above true for the file a hand-edit actually breaks. A syntax
  # error is the easy case; `base-url = 5` is the one an operator writes, and it
  # used to escape as a raise, which the channel's `rescue` turned into
  # `invalid_payload`: a false code, since the payload was fine and the file was
  # not.
  defp load_for_record(path) do
    DotConfig.load(path)
  rescue
    error -> {:error, Exception.message(error)}
  end

  # What the overlay already holds, for the two things this write has to keep:
  # the providers it records as deleted, and the api keys it stores — the browser
  # sends back only a key the operator just typed (#202).
  #
  # A missing file holds nothing, which is a fact; a file that cannot be read or
  # parsed is not, so the write stops rather than guessing at either.
  defp previous_local(file) do
    if File.exists?(file) do
      case load_for_record(file) do
        {:ok, config} ->
          {:ok, %{deleted: config.deleted_providers, providers: config.providers}}

        {:error, reason} ->
          {:error, "cannot use #{file} to keep its deleted providers and api keys: #{reason}"}
      end
    else
      {:ok, %{deleted: [], providers: %{}}}
    end
  end

  # The api key each provider's line carries, after the merge described in the
  # moduledoc. `api_key` is the only field this write reads from the overlay;
  # everything else in the payload is authoritative.
  defp with_api_keys(providers, previous, base) do
    Enum.map(providers, fn provider ->
      %{provider | api_key: merged_api_key(provider, previous, base)}
    end)
  end

  defp merged_api_key(%{api_key_source: :clear}, _previous, _base), do: ""

  defp merged_api_key(%{api_key_source: :set, api_key: key}, _previous, _base), do: key

  defp merged_api_key(%{api_key_source: :keep, name: name}, previous, _base) do
    # The overlay's own line, or nothing: an omission lets the merge inherit the
    # base's, so writing the base's value here would copy a secret into the
    # overlay for no reason.
    api_key_of(Map.get(previous.providers, name))
  end

  defp merged_api_key(%{api_key_source: {:renamed_from, previous_name}}, previous, base) do
    # The old block is being dropped or tombstoned, so the key has to travel —
    # including one that lives only in `config.toml`, under the old name.
    api_key_of(Map.get(previous.providers, previous_name)) ||
      api_key_of(Map.get(base, previous_name))
  end

  defp api_key_of(nil), do: nil
  defp api_key_of(%Provider{api_key: key}), do: key

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
