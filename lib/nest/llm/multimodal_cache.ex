defmodule Nest.LLM.MultimodalCache do
  @moduledoc """
  Persistent cache of multi-modal probe verdicts.

  `Nest.LLM.MultimodalProbe` costs an HTTP request per model, so its
  answer is remembered in `probe-cache.json`, next to `local.toml` in
  the config directory, and reused across restarts. A cached verdict is
  only ever a *substitute for probing*: a definite answer from the
  provider's `/models` body still wins (see `Nest.Models.MultiModal`),
  and a static `multi-modal` stays authoritative over both.

  ## Key

  An entry is keyed by provider name, then by model id, and is only
  usable while the stored endpoint still describes the provider:
  `base_url`, `protocol`, and a fingerprint of the resolved API key.
  Point the provider at another host, switch protocols, or paste a new
  key and its stored verdicts stop matching, because the probe's answer
  was about *that* endpoint. The key itself is never written anywhere —
  only a truncated SHA-256 of it.

  ## Lifetime

  Every entry carries its own `ttl_s` (one week) and `probed_at`, and
  expires on read. The file is a plain JSON document the user may delete
  or hand-edit at any time: a missing, unreadable, or malformed
  *document* is an empty cache — a miss, not an error — and a malformed
  *entry* is dropped on its own. `clear/0` empties it.

  ## Writes

  Reads happen in the calling process: the file is small, and a hit is
  the whole point of the cache. Writes are serialized through this named
  GenServer and land atomically, so concurrent probes cannot interleave
  and a reader never sees a half-written file.
  """

  use GenServer

  require Logger

  alias Nest.DotConfig
  alias Nest.DotConfig.Provider
  alias Nest.DotConfig.Writer

  @version 1
  @ttl_s 604_800
  @fingerprint_bytes 12

  @type verdict :: :positive | :negative

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  The path of the cache file.

  This is the seam tests stub to stay off the user's real config
  directory; in `:test` it always resolves under the system temp
  directory, and its name carries the OS process's pid, so two suites
  running at once cannot share one file.
  """
  @spec path() :: String.t()
  def path, do: default_path()

  @doc """
  The cached verdict for `model_id` under `provider`, or `nil` when the
  cache holds no usable entry for it.

  A read: the file is loaded in the calling process, and anything
  unreadable, unrecognized, or expired is a miss rather than an error.
  """
  @spec get(Provider.t(), String.t()) :: verdict() | nil
  def get(%Provider{} = provider, model_id) do
    with %{} = block <- provider_block(load_providers(__MODULE__.path()), provider.name),
         true <- block["endpoint"] == endpoint_of(provider),
         {:ok, verdict} <- live_verdict(block, model_id, now()) do
      verdict
    else
      _ -> nil
    end
  end

  @doc """
  Remember `verdict` for `model_id` under `provider`.

  Only the two definite verdicts are stored: `:unknown` is not a
  finding, and caching it would let one transient probe failure keep a
  model text-only for a week. Returns `:ok` either way, including when
  the file cannot be written — that is logged as a warning.
  """
  @spec put(Provider.t(), String.t(), verdict() | :unknown) :: :ok
  def put(%Provider{} = provider, model_id, verdict) when verdict in [:positive, :negative],
    do: GenServer.call(__MODULE__, {:put, __MODULE__.path(), provider, model_id, verdict})

  def put(%Provider{}, model_id, _verdict) when is_binary(model_id), do: :ok

  @doc """
  Empty the cache. Idempotent: clearing an absent or already-empty cache
  is a no-op that still leaves a valid (empty) document behind.

  A probe already in flight is unaffected — the verdict it settles on is
  written normally — so a clear mid-scan means "forget what we knew
  before this scan", never "lose this scan's findings".
  """
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, {:clear, __MODULE__.path()})

  @doc """
  What the cache currently holds, for the UI's clear button: the number
  of live entries, the age in seconds of the oldest one (`nil` when
  empty), and the file path.

  Expired entries are not counted: their bytes are still on disk, but
  they are not answers the cache would hand out. The endpoint
  fingerprint is deliberately *not* checked here — there is no provider
  struct to compare against — so a provider whose endpoint changed can
  still be counted until the next write rewrites its block.
  """
  @spec stats() :: %{
          entries: non_neg_integer(),
          oldest_age_s: non_neg_integer() | nil,
          path: String.t()
        }
  def stats do
    now = now()

    ages =
      for {_name, block} <- load_providers(__MODULE__.path()),
          entry <- entries_of(block),
          {:ok, _verdict, probed_at} <- [live_entry(entry, now)] do
        age_seconds(probed_at, now)
      end

    %{entries: length(ages), oldest_age_s: oldest_age(ages), path: __MODULE__.path()}
  end

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:put, file, provider, model_id, verdict}, _from, state) do
    providers = put_entry(load_providers(file), provider, model_id, verdict)
    {:reply, persist(file, providers), state}
  end

  def handle_call({:clear, file}, _from, state) do
    {:reply, persist(file, %{}), state}
  end

  defp default_path do
    if Mix.env() == :test do
      Path.join(System.tmp_dir!(), "nest-probe-cache-#{System.pid()}.json")
    else
      Path.join(DotConfig.config_dir(), "probe-cache.json")
    end
  end

  # The document is the cache's own, so it is versioned: a future format
  # change starts from an empty cache instead of misreading old entries.
  # `providers` mirrors `local.toml`'s shape, provider name -> its block.
  defp load_providers(file) do
    with {:ok, binary} <- File.read(file),
         {:ok, %{"version" => @version, "providers" => %{} = providers}} <- Jason.decode(binary) do
      providers
    else
      _ -> %{}
    end
  end

  defp provider_block(providers, name) do
    case Map.get(providers, name) do
      %{} = block -> block
      _ -> nil
    end
  end

  defp entries_of(%{"multimodal" => %{} = models}), do: Map.values(models)
  defp entries_of(_block), do: []

  defp endpoint_of(%Provider{} = provider) do
    %{
      "base_url" => provider.base_url,
      "protocol" => provider.protocol,
      "key_fingerprint" => key_fingerprint(provider)
    }
  end

  # `resolve_api_key/1` raises on an unset `${ENV}` reference or an
  # unreadable `file:` key, and a key we cannot resolve is one we cannot
  # fingerprint, so such an entry carries `nil` instead. Two `nil`s
  # compare equal, which is what a provider with no key at all (a local
  # server) needs; a provider whose key later *does* resolve
  # fingerprints differently, so its stored verdicts stop matching. That
  # is the safe direction either way, since a mismatch costs a re-probe
  # and can never produce a wrong hit.
  defp key_fingerprint(%Provider{} = provider) do
    case DotConfig.resolve_api_key(provider.api_key) do
      key when is_binary(key) -> "sha256:" <> fingerprint(key)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp fingerprint(key) do
    :crypto.hash(:sha256, key)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @fingerprint_bytes)
  end

  defp put_entry(providers, %Provider{} = provider, model_id, verdict) do
    endpoint = endpoint_of(provider)

    models =
      providers
      |> provider_block(provider.name)
      |> current_models(endpoint)
      |> Map.put(model_id, entry(verdict))

    Map.put(providers, provider.name, %{"endpoint" => endpoint, "multimodal" => models})
  end

  # A verdict describes the endpoint it was probed from, so a provider
  # whose endpoint changed starts its model map over rather than having
  # old answers attributed to the new endpoint.
  defp current_models(%{"endpoint" => stored, "multimodal" => %{} = models}, endpoint)
       when stored == endpoint,
       do: models

  defp current_models(_block, _endpoint), do: %{}

  defp entry(verdict) do
    %{"verdict" => Atom.to_string(verdict), "probed_at" => iso8601(now()), "ttl_s" => @ttl_s}
  end

  # The one usability check `get/2` and `stats/0` share: a well-formed,
  # unexpired entry. Anything else about an entry — extra keys, a
  # hand-edited `ttl_s` — is ignored, or falls back to the default.
  defp live_entry(%{} = entry, now) do
    with {:ok, verdict} <- parse_verdict(entry["verdict"]),
         {:ok, probed_at} <- parse_time(entry["probed_at"]),
         false <- expired?(probed_at, ttl_of(entry), now) do
      {:ok, verdict, probed_at}
    else
      _ -> :error
    end
  end

  defp live_entry(_entry, _now), do: :error

  defp live_verdict(block, model_id, now) do
    with %{"multimodal" => %{} = models} <- block,
         %{} = entry <- Map.get(models, model_id),
         {:ok, verdict, _probed_at} <- live_entry(entry, now) do
      {:ok, verdict}
    else
      _ -> :error
    end
  end

  defp parse_verdict("positive"), do: {:ok, :positive}
  defp parse_verdict("negative"), do: {:ok, :negative}
  defp parse_verdict(_other), do: :error

  defp parse_time(binary) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, probed_at, _offset} -> {:ok, probed_at}
      _ -> :error
    end
  end

  defp parse_time(_other), do: :error

  defp ttl_of(%{"ttl_s" => ttl_s}) when is_integer(ttl_s) and ttl_s > 0, do: ttl_s
  defp ttl_of(_entry), do: @ttl_s

  defp expired?(probed_at, ttl_s, now), do: DateTime.diff(now, probed_at, :second) >= ttl_s

  defp age_seconds(probed_at, now), do: max(DateTime.diff(now, probed_at, :second), 0)

  defp oldest_age([]), do: nil
  defp oldest_age(ages), do: Enum.max(ages)

  defp write_doc(file, providers) do
    doc = %{"version" => @version, "written_at" => iso8601(now()), "providers" => providers}

    with {:ok, json} <- Jason.encode(doc, pretty: true) do
      Writer.write_atomic(file, [json, ?\n])
    end
  end

  defp persist(file, providers) do
    case write_doc(file, providers) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("MultimodalCache: cannot write #{file}: #{inspect(reason)}")
    end
  end

  defp now, do: DateTime.utc_now()

  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
