defmodule Nest.EndpointCache do
  @moduledoc """
  In-memory cache of probed provider endpoint structures.

  Backed by a named ETS table so reads (`get/1`) are lock-free and
  cheap — the hot path (every agent spawn / chat config build) reads
  the cache but never blocks on the network. The probe itself is run
  by `Nest.EndpointProbe`; this process only owns the cache and
  triggers probes on demand (`probe_and_cache/1`) or at warm-up.

  Entries persist until invalidated — there is no TTL. Invalidation is
  event-driven: callers (e.g. `Nest.ChatModel`) invalidate and re-probe
  when a cached discovery endpoint starts returning `404`.
  """

  use GenServer

  alias Nest.DotConfig
  alias Nest.EndpointProbe

  @table :nest_endpoint_cache

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Return the cached `Nest.EndpointProbe.EndpointStructure` for a
  provider, or `nil` when it hasn't been probed. A lock-free ETS read.
  """
  @spec get(DotConfig.Provider.t()) :: EndpointProbe.EndpointStructure.t() | nil
  def get(provider) do
    case :ets.lookup(@table, cache_key(provider)) do
      [{_key, structure}] -> structure
      [] -> nil
    end
  end

  @doc """
  Probe a provider, cache the result, and return it.

  The probe runs in the *caller* process (so blocking HTTP never ties
  up this GenServer); only the storage of the resolved structure is
  delegated here.
  """
  @spec probe_and_cache(DotConfig.Provider.t()) ::
          {:ok, EndpointProbe.EndpointStructure.t()} | {:error, :unreachable}
  def probe_and_cache(provider) do
    case EndpointProbe.probe(provider) do
      {:ok, structure} ->
        GenServer.call(__MODULE__, {:cache_structure, provider, structure})
        {:ok, structure}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Drop the cached structure for a provider.
  """
  @spec invalidate(DotConfig.Provider.t()) :: :ok
  def invalidate(provider) do
    GenServer.call(__MODULE__, {:invalidate, provider})
  end

  @doc """
  Probe and cache every `auto_models` provider (startup warm-up).
  """
  @spec warm_up() :: :ok
  def warm_up, do: GenServer.call(__MODULE__, :warm_up)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Warm the cache from real config at startup, but never in tests —
    # tests stub `Req` and shouldn't spawn background HTTP against the
    # real config providers.
    if Mix.env() != :test do
      send(self(), :warm_up)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:cache_structure, provider, structure}, _from, state) do
    :ets.insert(@table, {cache_key(provider), structure})
    {:reply, :ok, state}
  end

  def handle_call({:invalidate, provider}, _from, state) do
    :ets.delete(@table, cache_key(provider))
    {:reply, :ok, state}
  end

  def handle_call(:warm_up, _from, state) do
    # Run the warm-up probes in a separate process so the GenServer
    # isn't blocked — the probes call `probe_and_cache/1` (a call back
    # into this process) and would otherwise deadlock.
    spawn(fn -> run_warm_up() end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:warm_up, state) do
    spawn(fn -> run_warm_up() end)
    {:noreply, state}
  end

  defp run_warm_up do
    with {:ok, config} <- DotConfig.load() do
      config.providers
      |> Kernel.||(%{})
      |> Map.values()
      |> Enum.filter(& &1.auto_models)
      |> Enum.each(&probe_and_cache/1)
    end

    :ok
  end

  defp cache_key(provider), do: {provider.name, provider.base_url}
end
