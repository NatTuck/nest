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
      completion broadcast reflects the new static_config (the
      merge uses the current state, not the snapshot the Task
      was started with).

  ## Reads

  `list/0`, `context_limit/2`, `loading?/0` are synchronous
  `GenServer.call`s that read the current state in microseconds.

  ## PubSub

  Topic: `"models"`. Subscribers receive `{:models_updated, payload}`
  on every successful scan completion (payload matches `list/0`'s
  shape — string-keyed JSON-safe map). `reload_static/0` also
  broadcasts when no scan is running.

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
  broadcast covers any subscriber that was waiting.

  Subscribers (see moduledoc) receive `{:models_updated, payload}`
  on scan completion.
  """
  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @doc """
  Synchronously reload `~/.config/nest/config.toml` from disk and
  update the cached `static_config`. Fast (single file read), no
  HTTP. Independent of scan state — does not affect the in-flight
  scan if one is running.

  When no scan is in flight, broadcasts `{:models_updated, payload}`
  on the `"models"` PubSub topic. When a scan is in flight, its
  completion broadcast will reflect the new static_config (because
  the merge uses the current state, not the snapshot the Task was
  started with).

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
           machine: :idle,
           scan_task_ref: nil
         }}

      {:error, reason} ->
        Logger.error("Failed to load config: #{inspect(reason)}")

        {:ok,
         %{
           static_config: %{models: %{}},
           auto_models: %{},
           context_limits: %{},
           machine: :idle,
           scan_task_ref: nil
         }}
    end
  end

  @impl true
  def handle_info(:startup_scan, state) do
    task = start_scan_task(state.static_config)
    {:noreply, %{state | machine: :scanning, scan_task_ref: task.ref}}
  end

  def handle_info({ref, result}, %{scan_task_ref: ref} = state) do
    # Task completed successfully. Merge uses the *current* static_config
    # so that if `reload_static/0` updated state.static_config during
    # this scan, the broadcast reflects the new static info.
    new_state = %{
      state
      | machine: :idle,
        scan_task_ref: nil,
        auto_models: result.auto_models,
        context_limits: result.limits_by_provider
    }

    payload = build_model_list(new_state)
    Phoenix.PubSub.broadcast(Nest.PubSub, "models", {:models_updated, payload})

    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{scan_task_ref: ref} = state) do
    Logger.warning("Models scan task crashed: #{inspect(reason)}")
    {:noreply, %{state | machine: :idle, scan_task_ref: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast(:refresh, state) do
    case state.machine do
      :scanning ->
        # Coalesce silently. PubSub broadcast when current scan
        # completes covers any subscriber that was waiting.
        {:noreply, state}

      :idle ->
        task = start_scan_task(state.static_config)
        {:noreply, %{state | machine: :scanning, scan_task_ref: task.ref}}
    end
  end

  @impl true
  def handle_call(:reload_static, _from, state) do
    state =
      case DotConfig.load() do
        {:ok, config} ->
          %{state | static_config: config}

        {:error, reason} ->
          Logger.error("Failed to reload static config: #{inspect(reason)}")
          state
      end

    # If no scan is running, broadcast immediately so subscribers
    # see the new static config without waiting for a refresh.
    # If a scan is running, the in-flight scan's broadcast at
    # completion will reflect the new static_config (the merge
    # in handle_info({ref, result}, state) uses the *current*
    # state.static_config, not the snapshot the Task was started
    # with).
    if state.machine == :idle do
      Phoenix.PubSub.broadcast(
        Nest.PubSub,
        "models",
        {:models_updated, build_model_list(state)}
      )
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
    {:reply, state.machine == :scanning, state}
  end

  # Private functions

  # Spawn a scan Task via the dedicated Task.Supervisor. The Task
  # runs in parallel with the GenServer's mailbox; result is
  # delivered as `{ref, result}` (Task.async semantics) and a
  # `:DOWN` if it crashes.
  defp start_scan_task(static_config) do
    Task.Supervisor.async(Nest.Models.TaskSupervisor, fn ->
      do_query_auto_providers(static_config)
    end)
  end

  # Query every `auto_models` provider, in parallel, with
  # per-provider try/rescue. Each provider is independent — a
  # failure is logged and dropped from that scan's results.
  # Returns always `%{auto_models: ..., limits_by_provider: ...}`
  # (never raises). The merged view is computed at read time
  # in `build_model_list/1`.
  defp do_query_auto_providers(static_config) do
    static_config
    |> auto_providers()
    |> Enum.map(&run_provider_query/1)
    |> Enum.map(&Task.await(&1, :infinity))
    |> merge_query_results()
  end

  defp auto_providers(static_config) do
    static_config.providers
    |> Kernel.||(%{})
    |> Map.values()
    |> Enum.filter(& &1.auto_models)
  end

  defp run_provider_query(provider) do
    Task.async(fn ->
      try do
        query_provider(provider)
      rescue
        e -> {:error, provider.name, e}
      catch
        kind, reason -> {:error, provider.name, {kind, reason}}
      end
    end)
  end

  defp merge_query_results(results) do
    {auto_models, limits_by_provider, failures} =
      Enum.reduce(results, {%{}, %{}, []}, &merge_one_result/2)

    log_provider_failures(failures)

    %{auto_models: auto_models, limits_by_provider: limits_by_provider}
  end

  defp merge_one_result({models, limits}, {am, al, errs}) do
    {Map.merge(am, models), Map.merge(al, limits), errs}
  end

  defp merge_one_result({:error, name, reason}, {am, al, errs}) do
    {am, al, [{name, reason} | errs]}
  end

  defp log_provider_failures([]), do: :ok

  defp log_provider_failures(failures) do
    Logger.warning(
      "Models scan: #{length(failures)} provider(s) failed: " <>
        Enum.map_join(failures, ", ", fn {name, _} -> name end)
    )
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
  defp build_model_list(%{auto_models: auto, static_config: %{models: static}} = state) do
    cache = state.context_limits
    providers = state.static_config.providers || %{}

    Map.merge(auto, static)
    |> Map.values()
    |> Enum.map(fn model ->
      %{
        "name" => model.name,
        "provider" => model.provider_name,
        "context_limit" => effective_context_limit(model, cache, providers)
      }
    end)
  end

  defp build_model_list(state) do
    # Fallback for state shapes where `static_config` doesn't carry
    # a `:models` map (e.g. the load-failed init/1 path). Returns
    # just the auto-discovered entries with no static overlay.
    cache = Map.get(state, :context_limits, %{})
    providers = (state.static_config && state.static_config.providers) || %{}

    state.auto_models
    |> Map.values()
    |> Enum.map(fn model ->
      %{
        "name" => model.name,
        "provider" => model.provider_name,
        "context_limit" => effective_context_limit(model, cache, providers)
      }
    end)
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
