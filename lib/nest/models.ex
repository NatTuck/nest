defmodule Nest.Models do
  @moduledoc """
  GenServer that manages the merged list of static and auto-discovered models.

  On startup, loads static models from DotConfig and queries
  auto-providers for their available models. Caches the merged
  result for fast access, and caches each auto-provider model's
  context-window limit (extracted from the same `/models`
  response) keyed by `{provider, model_id}`.

  ## Context-limit cache

  `context_limit/2` returns the cached `{source, limit}` for a
  model — the same `{source, limit}` produced by the per-agent
  async probe before this change, but lifted out of the agent's
  lifecycle. The cache is populated once per auto-provider on
  application startup (and on `refresh/0`); subsequent agent
  starts read from the cache synchronously without any
  network I/O.

  The cache and the merged model list are deliberately the
  same fetch — `Nest.LLM.ChatModel.list_models/1` returns
  the model names, and `Nest.LLM.ProviderShapes.extract_limit_from_model/1`
  reuses the same response body to extract the limit.
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
  - "name" - Model name
  - "provider" - Provider name
  - "context_limit" - Context limit (may be nil)
  """
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Refreshes the model list by re-querying auto-providers.
  Also re-populates the context-limit cache.

  ## Options

    * `:reload_static` (default `false`) — when `true`, also
      re-read `~/.config/nest/config.toml` from disk before
      the auto-discovery pass. This makes adding a new
      `[providers.<n>]` entry in the file take effect without
      an app restart. The static-config snapshot is otherwise
      captured once at `init/1` time.
  """
  def refresh(opts \\ []) do
    GenServer.cast(__MODULE__, {:refresh, opts})
  end

  @doc """
  Look up the cached context-limit source + value for a model.

  Returns `{source, limit}` when known, or `nil` when unknown.
  Sources are provider-shape atoms (`:vllm`, `:openrouter`,
  `:llama_cpp`).

  Reads the synchronous cache; never blocks on a network call.
  The cache is populated by `:query_auto_providers` on
  application startup (and on `refresh/0`).
  """
  @spec context_limit(provider :: String.t() | nil, model_id :: String.t() | nil) ::
          {source(), pos_integer()} | nil
  def context_limit(nil, _model_id), do: nil
  def context_limit(_provider, nil), do: nil

  def context_limit(provider, model_id) do
    GenServer.call(__MODULE__, {:context_limit, provider, model_id})
  end

  # Server callbacks

  @impl true
  def init(_) do
    case DotConfig.load() do
      {:ok, config} ->
        send(self(), :query_auto_providers)
        {:ok, %{static_config: config, models: %{}, context_limits: %{}}}

      {:error, reason} ->
        Logger.error("Failed to load config: #{inspect(reason)}")
        {:ok, %{static_config: %{models: %{}}, models: %{}, context_limits: %{}}}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    models_list = build_model_list(state)
    {:reply, models_list, state}
  end

  @impl true
  def handle_call({:context_limit, provider, model_id}, _from, state) do
    case get_in(state.context_limits, [provider, model_id]) do
      nil -> {:reply, nil, state}
      {source, limit} -> {:reply, {source, limit}, state}
    end
  end

  @impl true
  def handle_cast({:refresh, opts}, state) when is_list(opts) do
    # When `:reload_static` is set, re-parse the dotconfig from
    # disk so adding a new `[providers.<n>]` entry takes effect
    # without a server restart. The file path comes from
    # `DotConfig.load/0` (XDG-resolved at call time). Errors are
    # logged but non-fatal — the previous `state.static_config`
    # is kept so a malformed edit doesn't wipe the model catalog.
    state =
      if opts[:reload_static] do
        case DotConfig.load() do
          {:ok, config} ->
            %{state | static_config: config}

          {:error, reason} ->
            Logger.error("Failed to reload static config during refresh: #{inspect(reason)}")
            state
        end
      else
        state
      end

    send(self(), :query_auto_providers)
    {:noreply, state}
  end

  @impl true
  def handle_info(:query_auto_providers, %{static_config: config} = state) do
    # Get auto-providers (those with auto_models = true).
    auto_providers =
      config.providers
      |> Map.values()
      |> Enum.filter(& &1.auto_models)

    # Query each auto-provider for models and merge into single map.
    # Same fetch populates the context-limit cache via
    # `extract_limit_from_model/1`.
    {auto_models, limits_by_provider} =
      Enum.reduce(auto_providers, {%{}, %{}}, fn provider, {acc_models, acc_limits} ->
        {models, limits} = query_provider(provider)
        {Map.merge(acc_models, models), Map.merge(acc_limits, limits)}
      end)

    merged_models = Map.merge(auto_models, config.models)

    {:noreply, %{state | models: merged_models, context_limits: limits_by_provider}}
  end

  # Private functions

  # Auto-discovered models are registered in `Models.list/0`
  # regardless of whether a recognized context-window field is
  # present in the response — `ChatModel.list_models/1`
  # returns names only, while `ChatModel.list_models_with_limits/1`
  # is the (separate, filtered) source for the cache.
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

  # Composes the merged model list for `Models.list/0`. The
  # `context_limit` returned per entry is the *effective* value
  # (i.e. "the number the app will use") resolved across the
  # three layers in priority order:
  #
  #   1. Per-model static `context-limit` (already on the merged
  #      `DotConfig.Model` struct when present in TOML)
  #   2. Auto-discovery cache (per-{provider, model_id})
  #   3. Provider-level `default-context-limit`
  #
  # Computed at read time so a future re-parse of dotconfig
  # takes effect without forcing a refresh of the GenServer.
  defp build_model_list(%{models: models} = state) do
    cache = Map.get(state, :context_limits, %{})
    providers = provider_map(state)

    models
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

  defp provider_map(%{static_config: %{providers: providers}}), do: providers
  defp provider_map(_), do: %{}
end
