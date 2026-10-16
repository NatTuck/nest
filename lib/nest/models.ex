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
      the in-flight scan otherwise) and returns the scan id. A
      per-provider `{:models_updated, _}` is a *partial*: the only
      signal that a rescan is finished is the scan's terminal
      `{:models_scan_complete, %{scan_id: id, ...}}` broadcast.

  ## Streaming scans

  A scan queries every auto-models provider concurrently. Each
  provider's result is delivered to the GenServer as it completes,
  merged into the scan's accumulator, and broadcast immediately as
  `{:models_updated, payload}`. This means subscribers may see
  several `{:models_updated, _}` broadcasts per scan — one per
  provider response.

  Every scan ends with **exactly one** terminal broadcast,
  `{:models_scan_complete, %{scan_id: id, models: payload}}`:
  emitted when the last pending provider answers, or when the
  5000ms deadline fires with providers still pending. The scan
  stays alive after the deadline so late answers still produce
  `models_updated`, but no second completion is emitted. The
  deadline timer is cancelled when a scan finishes (or is
  replaced), so a stale timer can never announce completion for a
  later scan.

  ## Reads

  `list/0`, `context_limit/2`, `loading?/0` are synchronous
  `GenServer.call`s that read the current state in microseconds.

  ## PubSub

  Topic: `"models"`. Subscribers receive `{:models_updated, payload}`
  on every scan progress event (payload matches `list/0`'s shape —
  string-keyed JSON-safe map) plus `reload_static/0`'s immediate
  broadcast when no scan is running. Each scan also emits exactly
  one terminal `{:models_scan_complete, %{scan_id: id, models: payload}}`
  (see "Streaming scans").

  The standard sub-then-list flow:

      Phoenix.PubSub.subscribe(Nest.PubSub, "models")
      current = Models.list()              # catch-up read
      receive do
        {:models_updated, payload} -> ...        # future partial updates
        {:models_scan_complete, %{}} -> ...      # scan finished
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
  alias Nest.Models.Catalog
  alias Nest.Models.ContextLimits
  alias Nest.Models.MultiModal

  @type source :: Nest.LLM.Discover.source()

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
    * `"multi_modal"` — Multi-modal input vocabulary
      (`%{"input" => ["image"]}`): an explicit static `multi-modal`
      verbatim, with the scan's detection as a fill-in when static
      config sets nothing
    * `"thinking_levels"` — Thinking levels the model accepts
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
  if none is in flight. Returns the id of the scan that will cover
  this request (a fresh scan, or the in-flight scan it joined).

  Unlike `reload_static/0`, this never broadcasts a config-only
  payload; the next `{:models_updated, _}` always comes from scan
  progress. The authoritative "this rescan finished" signal is the
  scan's `{:models_scan_complete, %{scan_id: ^id, ...}}` broadcast,
  which is what the "rescan providers" button relies on so it stays
  disabled until every provider has actually answered.

  If a scan is already in flight, the config is still reloaded and
  the in-flight scan's subsequent broadcasts reflect it (the merge
  uses current state).
  """
  @spec rescan() :: pos_integer()
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
  Sources are the provider shapes that `Nest.LLM.Discover`
  recognizes; see `t:Nest.LLM.Discover.source/0`.

  Reads the synchronous cache; never blocks on a network call.
  """
  @spec context_limit(provider :: String.t() | nil, model_id :: String.t() | nil) ::
          {source(), pos_integer()} | nil
  def context_limit(nil, _model_id), do: nil
  def context_limit(_provider, nil), do: nil

  def context_limit(provider, model_id) do
    case ContextLimits.lookup(provider, model_id) do
      {:ok, limit} -> limit
      :unavailable -> GenServer.call(__MODULE__, {:context_limit, provider, model_id})
    end
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
        #
        # Never in tests: tests stub `Req` and drive scans explicitly
        # via `refresh/0` / `rescan/0`, and shouldn't spawn background
        # HTTP against the real config providers (mirroring
        # `Nest.EndpointCache.init/1`).
        if Mix.env() != :test do
          send(self(), :startup_scan)
        end

        ContextLimits.publish(%{})

        {:ok,
         %{
           static_config: config,
           auto_models: %{},
           context_limits: %{},
           scan: nil,
           last_scan_id: nil
         }}

      {:error, reason} ->
        Logger.error("Failed to load config: #{inspect(reason)}")

        ContextLimits.publish(%{})

        {:ok,
         %{
           static_config: %{models: %{}},
           auto_models: %{},
           context_limits: %{},
           scan: nil,
           last_scan_id: nil
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

      %{deadline_fired: true} ->
        {:noreply, state}

      scan ->
        # First-broadcast cap reached with providers still pending.
        # Broadcast the partial results and announce this scan's one
        # terminal completion now. The scan stays alive so late
        # answers still produce `models_updated`, but no second
        # completion is emitted.
        state = %{state | scan: %{scan | deadline_fired: true, timer: nil}}
        {:noreply, announce_complete(state, scan.id)}
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
    state = state |> put_reloaded_static() |> start_scan()
    {:reply, current_scan_id(state), state}
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
    {:reply, Catalog.build(state), state}
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
  # When it was the last pending provider, finalize and broadcast the
  # canonical list; otherwise broadcast the partial progress.
  defp handle_provider_progress(state, scan) do
    state = %{state | scan: scan}

    if MapSet.size(scan.pending) == 0 do
      {:noreply, finalize_scan(state)}
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

  # Start a scan unless one is already running and still within its
  # deadline. An in-flight scan covers the caller. A scan whose
  # deadline already fired is replaced so an explicit rescan is never
  # a permanent no-op.
  defp start_scan(%{scan: %{deadline_fired: false}} = state), do: state

  defp start_scan(%{scan: %{timer: timer}} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    do_start_scan(state)
  end

  defp start_scan(state), do: do_start_scan(state)

  defp do_start_scan(state) do
    providers = auto_providers(state.static_config)
    names = MapSet.new(providers, & &1.name)
    scan_id = System.unique_integer([:positive])

    # Seed the accumulator with the previous auto-discovered entries
    # for the providers this scan will query, so partial broadcasts
    # keep known models visible. Entries belonging to providers no
    # longer configured are dropped.
    auto_models =
      state.auto_models
      |> Enum.filter(fn {_k, model} -> MapSet.member?(names, model.provider_name) end)
      |> Map.new()

    context_limits = Map.take(state.context_limits, MapSet.to_list(names))

    scan = %{
      id: scan_id,
      pending: names,
      auto_models: auto_models,
      context_limits: context_limits,
      timer: nil,
      deadline_fired: false
    }

    state = %{state | scan: scan, last_scan_id: scan_id}

    if MapSet.size(names) == 0 do
      # No auto-providers: finish on the same tick instead of leaving
      # `scan` live until the deadline (which would make every later
      # `start_scan` a no-op).
      finalize_scan(state)
    else
      parent = self()

      Task.Supervisor.start_child(Nest.Models.TaskSupervisor, fn ->
        run_scan(parent, providers)
      end)

      timer = Process.send_after(self(), :models_scan_deadline, @default_deadline_ms)

      %{state | scan: %{scan | timer: timer}}
    end
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

  # Broadcast the in-flight scan accumulator (partial results). The
  # accumulator is the previous scan's completed maps seeded with the
  # providers this scan will query, so partial broadcasts never blank
  # the catalog.
  defp broadcast_scan(state) do
    broadcast(state)
    state
  end

  defp broadcast(state) do
    broadcast_payload(Catalog.build(state))
  end

  defp broadcast_payload(payload) do
    Phoenix.PubSub.broadcast(Nest.PubSub, "models", {:models_updated, payload})
  end

  # Broadcast the current list and this scan's single terminal
  # completion event. Called when the last provider answers, when a
  # scan has no providers, or when the deadline fires.
  defp announce_complete(state, scan_id) do
    payload = Catalog.build(state)
    broadcast_payload(payload)

    Phoenix.PubSub.broadcast(
      Nest.PubSub,
      "models",
      {:models_scan_complete, %{scan_id: scan_id, models: payload}}
    )

    state
  end

  # Every provider has answered (or the scan had no providers): fold
  # the accumulator into the canonical cache, cancel the deadline
  # timer, and end the scan. Emits the completion event unless the
  # deadline already did. The deadline message becomes a no-op once
  # `scan` is nil.
  defp finalize_scan(%{scan: scan} = state) when scan != nil do
    if is_reference(scan.timer), do: Process.cancel_timer(scan.timer)

    state = %{
      state
      | scan: nil,
        auto_models: scan.auto_models,
        context_limits: scan.context_limits
    }

    ContextLimits.publish(scan.context_limits)

    if scan.deadline_fired do
      # The deadline already emitted this scan's completion; surface
      # the late final list only.
      broadcast(state)
      state
    else
      announce_complete(state, scan.id)
    end
  end

  defp finalize_scan(state), do: state

  # The id of the scan that will cover a caller right now: the
  # in-flight scan's id, or the most recently started scan's id once
  # a zero-provider scan has already finalized.
  defp current_scan_id(%{scan: %{id: id}}), do: id
  defp current_scan_id(%{last_scan_id: id}), do: id

  defp auto_providers(static_config) do
    static_config.providers
    |> Kernel.||(%{})
    |> Map.values()
    |> Enum.filter(& &1.auto_models)
  end

  # Query a single provider with **one** `/models` request: the
  # discovery pass extracts the model names, their context-limit
  # source + value, and their multi-modal input support from the same
  # body. Returns `{models_map, limits_map}` where `models_map` has
  # `%{name => %DotConfig.Model{}}` shape (each model carrying what
  # the provider said about multi-modal input) and `limits_map` has
  # `%{model_id => {source, limit}}` shape.
  #
  # Empty maps on failure (`ChatModel.list_models_with_metadata/1`
  # swallows transport errors and returns `[]`).
  #
  # `Nest.Models.MultiModal.resolve/3` turns the body's answer into the
  # three-valued vocabulary, probing the model when the body left it
  # unknown and the provider opted in with `probe-multimodal`.
  #
  # Known defect: those probes run inline here, under this provider's Task,
  # while the scan's 5 s `@default_deadline_ms` bounds only the *first*
  # broadcast. Two 20 s probe requests per unknown model therefore outlive the
  # deadline: a probed model stays `multi_modal: nil` in the payload until
  # this query finishes and its late `models_updated` lands, and
  # `{:models_scan_complete, _}` -- which re-enables the GUI's rescan button
  # -- fires before the probes have answered. A correct fix needs a per-scan
  # probe budget (a deadline the probe path itself honours); the deadline's
  # current semantics are pre-existing and pinned by `test/nest/models_test.exs`.
  # Documented in `Nest.LLM.MultimodalProbe`'s "Cost and latency".
  defp query_provider(provider) do
    entries = ChatModel.list_models_with_metadata(provider)

    limits =
      entries
      |> Enum.reject(&is_nil(&1.source))
      |> Map.new(fn entry -> {entry.name, {entry.source, entry.limit}} end)

    models =
      entries
      |> Enum.map(fn entry ->
        {entry.name,
         %DotConfig.Model{
           name: entry.name,
           provider_name: provider.name,
           context_limit: nil,
           multi_modal: MultiModal.resolve(provider, entry.name, entry.multi_modal)
         }}
      end)
      |> Map.new()

    {models, %{provider.name => limits}}
  end
end
