defmodule Nest.ChatModel do
  @moduledoc """
  Wrapper around LangChain for creating LLM chains from config.
  """

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.ChatModels.ChatOpenAI
  alias Nest.DotConfig
  alias Nest.Models

  defmodule ModelNotFoundError do
    defexception [:message]
  end

  defmodule ProviderNotFoundError do
    defexception [:message]
  end

  @doc """
  Creates an LLMChain for the given model specification.

  Options:
    - :model - Model name (searches all providers)
    - :provider - Provider name (uses auto-discovery or first model)
    - :tag - Provider tag (searches providers by tag, uses first match)

  Examples:
    new(model: "gpt-4o")
    new(provider: "pegasus")
    new(provider: "model-studio", model: "qwen3-plus")
    new(tag: "local")
  """
  def new(opts \\ []) do
    # Get all models (static + auto-discovered)
    all_models = Models.list()
    config = DotConfig.load!()

    result =
      cond do
        model_name = opts[:model] ->
          # Find by model name
          find_by_model(all_models, config, model_name)

        provider_name = opts[:provider] ->
          # Find by provider
          find_by_provider(config, provider_name)

        tag = opts[:tag] ->
          # Find by provider tag
          find_by_tag(config, tag)

        true ->
          {:error, %ArgumentError{message: "Must specify :model, :provider, or :tag"}}
      end

    # Wrap the LLM in an LLMChain
    case result do
      {:ok, llm} -> {:ok, LLMChain.new!(%{llm: llm})}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates an LLMChain for the given model specification.
  Raises an exception if the model/provider is not found.
  """
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, chain} -> chain
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Creates a chat model from explicit provider and model info
  """
  def from_provider(provider_name, model_name \\ nil) do
    config = DotConfig.load!()
    provider = DotConfig.get_provider(config, provider_name)

    unless provider do
      raise ProviderNotFoundError, "Provider not found: #{provider_name}"
    end

    # Resolve the actual model name to use
    actual_model =
      if model_name do
        model_name
      else
        # Use first model from provider's explicit list
        if provider.models != [] do
          List.first(provider.models).name
        else
          # Auto-discovery - we'll need to check what's available
          nil
        end
      end

    build_chat_model(provider, actual_model)
  end

  # Private functions

  defp find_by_model(all_models, config, model_name) do
    # Find model in the merged list
    model = Enum.find(all_models, fn m -> m["name"] == model_name end)

    if model do
      provider_name = model["provider"]
      provider = DotConfig.get_provider(config, provider_name)
      build_chat_model(provider, model_name)
    else
      {:error, ModelNotFoundError.exception("Model not found: #{model_name}")}
    end
  end

  defp find_by_provider(config, provider_name) do
    provider = DotConfig.get_provider(config, provider_name)

    if provider do
      # If provider has explicit models, use the first one
      # Otherwise use nil and let it auto-discover
      model_name =
        if provider.models != [] do
          List.first(provider.models).name
        else
          nil
        end

      build_chat_model(provider, model_name)
    else
      {:error, ProviderNotFoundError.exception("Provider not found: #{provider_name}")}
    end
  end

  defp find_by_tag(config, tag) do
    providers = DotConfig.get_providers_by_tag(config, tag)

    case providers do
      [] ->
        {:error, ProviderNotFoundError.exception("No provider found with tag: #{tag}")}

      [provider | _] ->
        # Use first provider with this tag
        model_name =
          if provider.models != [] do
            List.first(provider.models).name
          else
            nil
          end

        build_chat_model(provider, model_name)
    end
  end

  @doc """
  Builds a chat model from a provider configuration.
  """
  def build_chat_model(%DotConfig.Provider{} = provider, model_name) do
    api_key = DotConfig.resolve_api_key(provider.api_key)

    # Auto-discover model if needed
    actual_model_name =
      if model_name do
        model_name
      else
        if provider.auto_models do
          discover_model(provider)
        else
          nil
        end
      end

    # Build appropriate chat model based on protocol
    case provider.protocol do
      "anthropic" ->
        build_anthropic_model(provider, actual_model_name, api_key)

      _openai ->
        # Default to OpenAI-compatible
        build_openai_model(provider, actual_model_name, api_key)
    end
  end

  defp build_openai_model(provider, model_name, api_key) do
    opts = %{
      endpoint: provider.base_url <> "/chat/completions",
      api_key: api_key,
      model: model_name
    }

    {:ok, ChatOpenAI.new!(opts)}
  end

  defp build_anthropic_model(provider, model_name, api_key) do
    opts = %{
      model: model_name,
      api_key: api_key
    }

    # Only set endpoint if base_url is provided and different from default
    opts =
      if provider.base_url && provider.base_url != "" do
        Map.put(opts, :endpoint, provider.base_url)
      else
        opts
      end

    {:ok, ChatAnthropic.new!(opts)}
  end

  @doc """
  Lists all available models from a provider by querying the /models endpoint.

  Returns a list of model names available from the provider.
  """
  def list_models(%DotConfig.Provider{} = provider) do
    url = provider.base_url <> "/models"
    headers = [{"Authorization", "Bearer #{DotConfig.resolve_api_key(provider.api_key)}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        extract_all_models(body)

      {:ok, %{status: status}} ->
        Logger.warning(
          "Provider returned status #{status} when listing models from #{provider.name}"
        )

        []

      {:error, reason} ->
        Logger.warning("Failed to list models from #{provider.name}: #{inspect(reason)}")
        []
    end
  end

  def list_models(provider_name) when is_binary(provider_name) do
    config = DotConfig.load!()
    provider = DotConfig.get_provider(config, provider_name)

    if provider do
      list_models(provider)
    else
      Logger.warning("Provider not found: #{provider_name}")
      []
    end
  end

  # Extract all model names from the API response
  defp extract_all_models(body) do
    models =
      case body do
        %{"data" => data} when is_list(data) ->
          Enum.map(data, fn
            %{"id" => model_id} -> model_id
            _ -> nil
          end)

        %{"models" => models} when is_list(models) ->
          Enum.map(models, fn
            %{"name" => model_name} -> model_name
            _ -> nil
          end)

        _ ->
          []
      end

    Enum.reject(models, &is_nil/1)
  end

  defp discover_model(provider) do
    case list_models(provider) do
      [first_model | _] -> first_model
      [] -> nil
    end
  end
end
