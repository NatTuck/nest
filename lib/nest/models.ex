defmodule Nest.Models do
  @moduledoc """
  **Non-blocking** GenServer that maintains a cached merged view of
  static (`~/.config/nest/config.toml`) and auto-discovered models.

  Per SMELLS.md:20-23, this GenServer does not block for an unknown
  amount of time. All HTTP I/O (auto-discovery queries) runs in a
  separate `Task.Supervisor` worker (`Nest.Models.TaskSupervisor`).
  The GenServer's own mailbox processes only metadata updates.

  ## Refresh

    * `refresh/0` — fire-and-forget cast. Spawns a scan if `:idle`,
      no-ops if `:scanning`. Callers that need fresh data should
      subscribe to the `"models"` PubSub topic.
    * `reload_static/0` — synchronous `config.toml` reload. Fast,
      no HTTP. Broadcasts `{:models_updated, payload}` immediately
      when no scan is running; if a scan is running, its
      partial/final broadcasts reflect the new static_config (the
      merge uses the current state, not the snapshot the scan
      captured at start).
    * `rescan/0` — the user-triggered path. Reloads `config.toml`
      **without** broadcasting, then starts a scan if idle (joins
      the in-flight scan otherwise). All broadcasts come from scan
      progress, so a subscriber that saw no broadcast before
      calling `rescan/0` knows the next one is genuinely fresh.

  ## Streaming scans

  A scan queries every auto-models provider concurrently. Each
  provider's result is delivered to the GenServer as it completes,
  merged into the scan's accumulator, and broadcast immediately.
  This means subscribers may see several `{:models_updated, _}`
  broadcasts per scan — one per provider response.

  A 5000ms deadline bounds the wait for the **first**
  broadcast: if not every provider has answered by then, the
  partial results are broadcast and the scan stays alive so late
  answers produce further broadcasts. The deadline timer is not
  reset by partial results — it is a single cap from scan start.

  ## Reads

  `list/0`, `context_limit/2`, `loading?/0` are synchronous
  `GenServer.call`s that read the current state in microseconds.

  ## PubSub

  Topic: `"models"`. Subscribers receive `{:models_updated, payload}`
  on every scan progress event (payload matches `list/0`'s shape —
  string-keyed JSON-safe map) plus `reload_static/0`'s immediate
  broadcast when no scan is running.

  The standard sub-then-list flow:

      Phoenix.PubSub.subscribe(Nest.PubSub, "models")
      current = Models.list()              # catch-up read
      receive do
        {:models_updated, payload} -> ...  # future updates
      end

  ## Partial failure

  Auto-discovery providers fail independently. A provider returning
  HTTP 500 or timing out is logged and dropped from that scan's
  results. If all providers fail, the scan completes with empty
  auto-discovered maps and the cache falls back to
  `static_config.models` only.
  """

  use GenServer

  require Logger

  alias Nest.ChatModel
  alias Nest.DotConfig

  @type source :: :vllm | :openrouter | :llama_cpp

  @default_deadline_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns the merged list of all models (static + auto-discovered).

  Models are returned as maps with string keys for JSON serialization:
    * `"name"` — Model name
    * `"provider"` — Provider name
    * `"context_limit"` — Effective context limit (per-model static,
      auto-discovery cache hit, or provider default)
  """
  @spec list() :: [map()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc """
  Kicks off an HTTP scan to refresh the auto-discovered model list.
  Fire-and-forget. Returns `:ok` immediately.

  No-op when a scan is already in flight — the in-flight scan's
  broadcasts cover any subscriber that was waiting.

  Subscribers (see moduledoc) receive `{:models_updated, payload}`
  as each provider answers and once more when the scan completes.
  """
  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @doc """
  Reload `~/.config/nest/config.toml` from disk, then start a scan
  if none is in flight. Fire-and-forget from the caller's
  perspective — returns `:ok` immediately.

  Unlike `reload_static/0`, this never broadcasts a config-only
  payload; the next `{:models_updated, _}` always comes from scan
  progress. That is what the "rescan providers" button relies on so
  it stays disabled until providers have actually answered.

  If a scan is already in flight, the config is still reloaded and
  the in-flight scan's subsequent broadcasts reflect it (the merge
  uses current state).
  """
  @spec rescan() :: :ok
  def rescan, do: GenServer.call(__MODULE__, :rescan)

  @doc """
  Synchronously reload `~/.config/nest/config.toml` from disk and
  update the cached `static_config`. Fast (single file read), no
  HTTP. Independent of scan state — does not affect the in-flight
  scan if one is running.

  When no scan is in flight, broadcasts `{:models_updated, payload}`
  on the `"models"` PubSub topic. When a scan is in flight, its
  progress broadcasts will reflect the new static_config (because
  the merge uses the current state, not the snapshot the scan
  captured at start).

  Errors during reload are logged but non-fatal — the previous
  `static_config` is preserved.
  """
  @spec reload_static() :: :ok
  def reload_static, do: GenServer.call(__MODULE__, :reload_static)

  @doc """
  Look up the cached context-limit source + value for a model.

  Returns `{source, limit}` when known, or `nil` when unknown.
  Sources are provider-shape atoms (`:vllm`, `:openrouter`,
  `:llama_cpp`).

  Reads the synchronous cache; never blocks on a network call.
  """
  @spec context_limit(provider :: String.t() | nil, model_id :: String.t() | nil) ::
          {source(), pos_integer()} | nil
  def context_limit(nil, _model_id), do: nil
  def context_limit(_provider, nil), do: nil

  def context_limit(provider, model_id) do
    GenServer.call(__MODULE__, {:context_limit, provider, model_id})
  end

  @doc """
  Returns `true` when a scan is currently in flight, `false` otherwise.
  """
  @spec loading?() :: boolean()
  def loading?, do: GenServer.call(__MODULE__, :loading?)

  # Server callbacks

  @impl true
  def init(_) do
    case DotConfig.load() do
      {:ok, config} ->
        # Deferred startup pattern — `send(self(), :startup_scan)` so
        # the supervisor's startup isn't blocked by HTTP. The first
        # scan will populate `auto_models` and `context_limits`.
        send(self(), :startup_scan)

        {:ok,
         %{
           static_config: config,
           auto_models: %{},
           context_limits: %{},
           scan: nil
         }}

      {:error, reason} ->
        Logger.error("Failed to load config: #{inspect(reason)}")

        {:ok,
         %{
           static_config: %{models: %{}},
           auto_models: %{},
           context_limits: %{},
           scan: nil
         }}
    end
  end

  @impl true
  def handle_info(:startup_scan, state) do
    {:noreply, start_scan(state)}
  end

  def handle_info({:models_provider_result, name, models, limits}, state) do
    case state.scan do
      %{pending: pending} = scan ->
        if MapSet.member?(pending, name) do
          scan =
            scan
            |> drop_provider(name)
            |> Map.put(:pending, MapSet.delete(pending, name))
            |> Map.update!(:auto_models, &Map.merge(&1, models))
            |> Map.update!(:context_limits, &Map.merge(&1, limits))

          handle_provider_progress(state, scan)
        else
          {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:models_provider_failed, name, reason}, state) do
    case state.scan do
      %{pending: pending} = scan ->
        if MapSet.member?(pending, name) do
          Logger.warning("Models scan: provider #{name} failed: #{inspect(reason)}")

          scan =
            scan
            |> drop_provider(name)
            |> Map.put(:pending, MapSet.delete(pending, name))

          handle_provider_progress(state, scan)
        else
          {:noreply, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:models_scan_deadline, state) do
    case state.scan do
      nil ->
        {:noreply, state}

      _scan ->
        # First-broadcast cap reached with providers still pending.
        # Broadcast the partial results now and keep the scan alive
        # so late answers broadcast again.
        {:noreply, broadcast_scan(state)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, start_scan(state)}
  end

  @impl true
  def handle_call(:rescan, _from, state) do
    # Reload config silently (no broadcast) so the next
    # `models_updated` subscribers see is scan progress, not a
    # config-only no-op.
    {:reply, :ok, state |> put_reloaded_static() |> start_scan()}
  end

  def handle_call(:reload_static, _from, state) do
    state = put_reloaded_static(state)

    # If no scan is running, broadcast immediately so subscribers
    # see the new static config without waiting for a refresh.
    # If a scan is running, its progress broadcasts reflect the new
    # static_config (the merge uses the *current* state, not the
    # snapshot the scan captured at start).
    if state.scan == nil do
      broadcast(state)
    end

    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, build_model_list(state), state}
  end

  def handle_call({:context_limit, provider, model_id}, _from, state) do
    case get_in(state.context_limits, [provider, model_id]) do
      nil -> {:reply, nil, state}
      {source, limit} -> {:reply, {source, limit}, state}
    end
  end

  def handle_call(:loading?, _from, state) do
    {:reply, state.scan != nil, state}
  end

  # Private functions

  defp put_reloaded_static(state) do
    case DotConfig.load() do
      {:ok, config} ->
        %{state | static_config: config}

      {:error, reason} ->
        Logger.error("Failed to reload static config: #{inspect(reason)}")
        state
    end
  end

  # A provider's answer (or failure) has been folded into the scan.
  # When it was the last pending provider, finish and broadcast the
  # canonical list; otherwise broadcast the partial progress.
  defp handle_provider_progress(state, scan) do
    state = %{state | scan: scan}

    if MapSet.size(scan.pending) == 0 do
      {:noreply, finish_scan(state)}
    else
      {:noreply, broadcast_scan(state)}
    end
  end

  # Remove a provider's entries from the scan accumulator. The
  # accumulator is seeded from the previous scan's completed maps, so
  # a provider must be cleared before merging its new answer —
  # otherwise models from a provider that disappeared (or now fails)
  # would linger forever.
  defp drop_provider(scan, name) do
    auto_models =
      Enum.reject(scan.auto_models, fn {_k, model} -> model.provider_name == name end)

    %{
      scan
      | auto_models: Map.new(auto_models),
        context_limits: Map.delete(scan.context_limits, name)
    }
  end

  # Start a scan when idle. When one is already running, no-op so
  # its in-flight broadcasts cover the caller. The deadline is a
  # single cap from scan start.
  defp start_scan(%{scan: scan} = state) when scan != nil, do: state

  defp start_scan(state) do
    providers = auto_providers(state.static_config)
    names = MapSet.new(providers, & &1.name)
    parent = self()

    Task.Supervisor.start_child(Nest.Models.TaskSupervisor, fn ->
      run_scan(parent, providers)
    end)

    Process.send_after(self(), :models_scan_deadline, @default_deadline_ms)

    # Seed the accumulator with the previous auto-discovered entries
    # for the providers this scan will query, so partial broadcasts
    # keep known models visible. Entries belonging to providers no
    # longer configured are dropped.
    auto_models =
      state.auto_models
      |> Enum.filter(fn {_k, model} -> MapSet.member?(names, model.provider_name) end)
      |> Map.new()

    context_limits = Map.take(state.context_limits, MapSet.to_list(names))

    %{
      state
      | scan: %{
          pending: names,
          auto_models: auto_models,
          context_limits: context_limits
        }
    }
  end

  defp run_scan(parent, providers) do
    providers
    |> Enum.map(&run_provider_query(&1, parent))
    |> Enum.each(&Task.await(&1, :infinity))
  end

  defp run_provider_query(provider, parent) do
    Task.async(fn ->
      try do
        {models, limits} = query_provider(provider)
        send(parent, {:models_provider_result, provider.name, models, limits})
      rescue
        e -> send(parent, {:models_provider_failed, provider.name, e})
      catch
        kind, reason -> send(parent, {:models_provider_failed, provider.name, {kind, reason}})
      end
    end)
  end

  # Merge the scan accumulator with current static config and
  # broadcast. Reads `state.scan` for the accumulator; no-op when
  # no scan is active.
  defp broadcast_scan(state) do
    broadcast(state)
    state
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(Nest.PubSub, "models", {:models_updated, build_model_list(state)})
  end

  # Every provider has answered: fold the accumulator into the
  # canonical cache, end the scan, and broadcast the final list. The
  # deadline message becomes a no-op once `scan` is nil.
  defp finish_scan(%{scan: scan} = state) when scan != nil do
    state = %{
      state
      | scan: nil,
        auto_models: scan.auto_models,
        context_limits: scan.context_limits
    }

    broadcast(state)
    state
  end

  defp finish_scan(state), do: state

  defp auto_providers(static_config) do
    static_config.providers
    |> Kernel.||(%{})
    |> Map.values()
    |> Enum.filter(& &1.auto_models)
  end

  # Query a single provider. The two HTTP calls (names + limits)
  # hit the same `/models` endpoint — current implementation
  # issues two requests. Returns `{models_map, limits_map}` where
  # `models_map` has `%{name => %DotConfig.Model{}}` shape and
  # `limits_map` has `%{model_id => {source, limit}}` shape.
  #
  # Empty maps on failure (the existing `ChatModel.list_models/1`
  # and `list_models_with_limits/1` swallow transport errors and
  # return `[]` / `%{}`).
  defp query_provider(provider) do
    names = ChatModel.list_models(provider)
    models_with_limits = ChatModel.list_models_with_limits(provider)

    limits =
      Map.new(models_with_limits, fn entry ->
        {entry.name, {entry.source, entry.limit}}
      end)

    models =
      names
      |> Enum.map(fn name ->
        {name,
         %DotConfig.Model{
           name: name,
           provider_name: provider.name,
           context_limit: nil,
           multi_modal: nil
         }}
      end)
      |> Map.new()

    {models, %{provider.name => limits}}
  end

  # Composes the merged model list for `Models.list/0`. Static
  # config wins over auto-discovery on name collisions. The
  # `context_limit` returned per entry is the *effective* value
  # resolved across the three layers in priority order:
  #
  #   1. Per-model static `context-limit` (already on the merged
  #      `DotConfig.Model` struct when present in TOML)
  #   2. Auto-discovery cache (per-{provider, model_id})
  #   3. Provider-level `default-context-limit`
  #
  # Computed at read time so a `reload_static/0` takes effect
  # immediately on the next read without forcing a refresh.
  defp build_model_list(state) do
    {auto, cache} = scan_view(state)
    providers = (state.static_config && state.static_config.providers) || %{}
    static = static_models(state)

    Map.merge(auto, static)
    |> Map.values()
    |> Enum.map(fn model ->
      %{
        "name" => model.name,
        "provider" => model.provider_name,
        "context_limit" => effective_context_limit(model, cache, providers),
        "thinking_levels" => thinking_levels()
      }
    end)
  end

  # While a scan is active, `state.auto_models`/`state.context_limits`
  # still hold the previous scan's completed values. Read from the
  # in-flight accumulator so partial results are visible; fall back
  # to the canonical fields when idle.
  defp scan_view(%{scan: %{auto_models: auto, context_limits: limits}}), do: {auto, limits}
  defp scan_view(state), do: {state.auto_models, state.context_limits}

  defp static_models(%{static_config: %{models: static}}) when is_map(static), do: static
  defp static_models(_state), do: %{}

  # The thinking levels a model can be configured with. Phase 1
  # exposes the full supported set for every model; narrowing per
  # model from provider capability discovery is future work.
  defp thinking_levels do
    Nest.DotConfig.thinking_efforts()
    |> Enum.map(&to_string/1)
  end

  defp effective_context_limit(model, cache, providers) do
    cond do
      is_integer(model.context_limit) ->
        model.context_limit

      limit = get_in(cache, [model.provider_name, model.name]) ->
        case limit do
          {_source, n} when is_integer(n) -> n
          _ -> provider_default(providers, model.provider_name)
        end

      true ->
        provider_default(providers, model.provider_name)
    end
  end

  defp provider_default(providers, provider_name) do
    case Map.get(providers, provider_name) do
      %{default_context_limit: limit} when is_integer(limit) -> limit
      _ -> nil
    end
  end
end
