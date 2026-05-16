defmodule Nest.Models do
  @moduledoc """
  GenServer that manages the merged list of static and auto-discovered models.

  On startup, loads static models from DotConfig and queries auto-providers
  for their available models. Caches the merged result for fast access.
  """

  use GenServer

  require Logger

  alias Nest.ChatModel
  alias Nest.DotConfig

  @doc """
  Starts the Models GenServer.
  """
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
  """
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # Server callbacks

  @impl true
  def init(_) do
    # Load static config
    case DotConfig.load() do
      {:ok, config} ->
        # Query auto-providers asynchronously
        send(self(), :query_auto_providers)
        {:ok, %{static_config: config, models: %{}}}

      {:error, reason} ->
        Logger.error("Failed to load config: #{inspect(reason)}")
        {:ok, %{static_config: %{models: %{}}, models: %{}}}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    models_list = build_model_list(state)
    {:reply, models_list, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :query_auto_providers)
    {:noreply, state}
  end

  @impl true
  def handle_info(:query_auto_providers, %{static_config: config} = state) do
    # Get auto-providers (those with auto_models = true)
    auto_providers =
      config.providers
      |> Map.values()
      |> Enum.filter(& &1.auto_models)

    # Query each auto-provider for models and merge into single map
    auto_models =
      Enum.reduce(auto_providers, %{}, fn provider, acc ->
        provider_models = query_provider_models(provider)
        Map.merge(acc, provider_models)
      end)

    # Merge static and auto models
    merged_models = Map.merge(config.models, auto_models)

    {:noreply, %{state | models: merged_models}}
  end

  # Private functions

  defp query_provider_models(provider) do
    case ChatModel.list_models(provider) do
      [] ->
        Logger.debug("No models found from auto-provider: #{provider.name}")
        %{}

      model_names ->
        Logger.debug("Found #{length(model_names)} models from auto-provider: #{provider.name}")

        # Create model structs for each discovered model
        model_names
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
    end
  end

  defp build_model_list(%{models: models}) do
    models
    |> Map.values()
    |> Enum.map(fn model ->
      %{
        "name" => model.name,
        "provider" => model.provider_name,
        "context_limit" => model.context_limit
      }
    end)
  end
end
