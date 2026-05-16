defmodule Nest.ChatModel do
  @moduledoc """
  Wrapper around LangChain for creating LLM chains from config.
  """

  require Logger

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatAnthropic
  alias LangChain.ChatModels.ChatOpenAI
  alias Nest.DotConfig

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
    config = DotConfig.load!()

    chat_model =
      cond do
        model_name = opts[:model] ->
          # Find by model name
          find_by_model(config, model_name)

        provider_name = opts[:provider] ->
          # Find by provider
          find_by_provider(config, provider_name)

        tag = opts[:tag] ->
          # Find by provider tag
          find_by_tag(config, tag)

        true ->
          raise ArgumentError, "Must specify :model, :provider, or :tag"
      end

    case chat_model do
      {:ok, llm} ->
        LLMChain.new!(%{llm: llm})

      {:error, reason} ->
        raise reason
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

  defp find_by_model(config, model_name) do
    model = DotConfig.get_model(config, model_name)

    if model do
      provider = DotConfig.get_provider(config, model.provider_name)
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

  defp build_chat_model(%DotConfig.Provider{} = provider, model_name) do
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

  defp discover_model(provider) do
    url = provider.base_url <> "/models"
    headers = [{"Authorization", "Bearer #{DotConfig.resolve_api_key(provider.api_key)}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        # Extract first model name from response
        case body do
          %{"data" => [%{"id" => model_id} | _]} ->
            model_id

          %{"models" => [%{"name" => model_name} | _]} ->
            model_name

          _ ->
            nil
        end

      _error ->
        nil
    end
  end
end
