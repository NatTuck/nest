defmodule Nest.ChatModel do
  @moduledoc """
  Resolves a model name (or provider, or tag) to an
  `Nest.LLM.ClientConfig` that the agent can drive.
  """

  require Logger

  alias Nest.DotConfig
  alias Nest.LLM.AnthropicClient
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.Discover
  alias Nest.LLM.OpenAIClient
  alias Nest.Models

  defmodule ModelNotFoundError do
    defexception [:message]
  end

  defmodule ProviderNotFoundError do
    defexception [:message]
  end

  @doc """
  Creates a client config for the given model specification.

  Options:
    - :model - Model name (searches all providers)
    - :provider - Provider name (uses auto-discovery or first model)
    - :tag - Provider tag (searches providers by tag, uses first match)

  Returns `{:ok, %ClientConfig{}}` for any provider that has a
  Nest-native client (OpenAI-compatible and Anthropic). The
  `:protocol` field on the provider selects the client.

  Examples:
    new(model: "gpt-4o")
    new(provider: "pegasus")
    new(provider: "model-studio", model: "qwen3-plus")
    new(tag: "local")
  """
  def new(opts \\ []) do
    all_models = Models.list()
    config = DotConfig.load!()

    result =
      cond do
        model_name = opts[:model] -> find_by_model(all_models, config, model_name)
        provider_name = opts[:provider] -> find_by_provider(config, provider_name)
        tag = opts[:tag] -> find_by_tag(config, tag)
        true -> {:error, %ArgumentError{message: "Must specify :model, :provider, or :tag"}}
      end

    case result do
      {:ok, config} -> {:ok, config}
      {:error, _} = err -> err
    end
  end

  @doc """
  Like `new/1` but raises on error. Useful for tests and eager
  initialization.
  """
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, config} -> config
      {:error, %ModelNotFoundError{} = err} -> raise err
      {:error, %ProviderNotFoundError{} = err} -> raise err
      {:error, %ArgumentError{} = err} -> raise err
      {:error, reason} -> raise "ChatModel.new! failed: #{inspect(reason)}"
    end
  end

  @doc """
  Creates a client config from explicit provider and model info.
  """
  def from_provider(provider_name, model_name \\ nil) do
    config = DotConfig.load!()
    provider = DotConfig.get_provider(config, provider_name)

    unless provider do
      raise ProviderNotFoundError, "Provider not found: #{provider_name}"
    end

    actual_model =
      if model_name do
        model_name
      else
        if provider.models != [] do
          List.first(provider.models).name
        else
          nil
        end
      end

    build_client_config(provider, actual_model)
  end

  @doc """
  Build a client config from a provider struct and a model name.
  """
  def build_client_config(%DotConfig.Provider{} = provider, model_name) do
    case provider.protocol do
      "anthropic" -> build_anthropic_config(provider, model_name)
      _ -> build_openai_config(provider, model_name)
    end
  end

  defp build_openai_config(provider, model_name) do
    api_key = DotConfig.resolve_api_key(provider.api_key)
    actual = ensure_model_name(provider, model_name)

    %ClientConfig{
      client: OpenAIClient,
      base_url: provider.base_url,
      api_key: api_key,
      model: actual,
      receive_timeout: receive_timeout_ms(provider),
      rewrite_late_system_messages: provider.rewrite_late_system_messages
    }
    |> wrap_ok()
  end

  defp build_anthropic_config(provider, model_name) do
    api_key = DotConfig.resolve_api_key(provider.api_key)
    actual = ensure_model_name(provider, model_name)

    %ClientConfig{
      client: AnthropicClient,
      base_url: provider.base_url,
      api_key: api_key,
      model: actual,
      receive_timeout: receive_timeout_ms(provider),
      rewrite_late_system_messages: provider.rewrite_late_system_messages
    }
    |> wrap_ok()
  end

  defp ensure_model_name(provider, model_name) do
    if model_name do
      model_name
    else
      if provider.auto_models, do: discover_model(provider), else: nil
    end
  end

  defp wrap_ok(value), do: {:ok, value}

  # Private functions

  defp find_by_model(all_models, config, model_name) do
    model = Enum.find(all_models, fn m -> m["name"] == model_name end)

    if model do
      provider_name = model["provider"]
      provider = DotConfig.get_provider(config, provider_name)
      build_client_config(provider, model_name)
    else
      {:error, ModelNotFoundError.exception("Model not found: #{model_name}")}
    end
  end

  defp find_by_provider(config, provider_name) do
    provider = DotConfig.get_provider(config, provider_name)

    if provider do
      model_name =
        if provider.models != [] do
          List.first(provider.models).name
        else
          nil
        end

      build_client_config(provider, model_name)
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
        model_name =
          if provider.models != [] do
            List.first(provider.models).name
          else
            nil
          end

        build_client_config(provider, model_name)
    end
  end

  @doc """
  Lists all available models from a provider by querying the /models endpoint.
  """
  def list_models(%DotConfig.Provider{} = provider) do
    case fetch_models_body(provider) do
      {:ok, body} ->
        extract_all_models(body)

      :error ->
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

  @doc """
  Like `list_models/1`, but returns one entry per model that
  carries both the name and the extracted context-limit
  source + value. Used by `Nest.Models` to populate its
  context-limit cache alongside the merged model list.

  Each entry has shape:

      %{name: String.t(), source: source(), limit: pos_integer()}

  Missing / unparseable entries are silently dropped; a
  failure to fetch any models returns `[]` so the caller
  can populate only the names it found.
  """
  @spec list_models_with_limits(DotConfig.Provider.t()) :: [map()]
  def list_models_with_limits(%DotConfig.Provider{} = provider) do
    case fetch_models_body(provider) do
      {:ok, body} ->
        body
        |> list_models_with_limits_from_body()

      :error ->
        []
    end
  end

  defp fetch_models_body(provider) do
    url = provider.base_url <> "/models"
    headers = [{"Authorization", "Bearer #{DotConfig.resolve_api_key(provider.api_key)}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        log_list_status(provider, status)
        :error

      {:error, reason} ->
        log_list_error(provider, reason)
        :error
    end
  end

  defp list_models_with_limits_from_body(body) do
    body
    |> extract_model_entries()
    |> Enum.flat_map(fn entry ->
      with name when is_binary(name) <- Discover.model_id(entry),
           {source, limit} when source != nil <- Discover.extract_limit_from_model(entry) do
        [%{name: name, source: source, limit: limit}]
      else
        _ -> []
      end
    end)
  end

  defp log_list_status(provider, status) do
    Logger.warning("Provider returned status #{status} when listing models from #{provider.name}")
  end

  defp log_list_error(provider, reason) do
    Logger.warning("Failed to list models from #{provider.name}: #{inspect(reason)}")
  end

  # Walk a /models response body and return one normalized
  # entry per model. Tolerant of OpenAI-shaped (`{"data": [...]}`)
  # and Ollama-shaped (`{"models": [...]}`) bodies, plus a bare
  # list. Each entry is the raw map that `extract_limit_from_model`
  # will inspect.
  defp extract_model_entries(body) do
    case body do
      %{"data" => data} when is_list(data) -> data
      %{"models" => models} when is_list(models) -> models
      list when is_list(list) -> list
      _ -> []
    end
  end

  # Extract model names from a /models response using the same
  # shape + field tolerance as `Discover.model_id/1`. Routes
  # OpenAI `{"data": [...]}`, Ollama `{"models": [...]}`,
  # and bare-list bodies through `extract_model_entries/1`
  # (which yields raw entries) and then resolves each entry's
  # id via `id` or `name`.
  defp extract_all_models(body) do
    body
    |> extract_model_entries()
    |> Enum.map(&Discover.model_id/1)
    |> Enum.reject(&is_nil/1)
  end

  defp discover_model(provider) do
    case list_models(provider) do
      [first_model | _] -> first_model
      [] -> nil
    end
  end

  defp receive_timeout_ms(provider) do
    seconds = provider.timeout_seconds || DotConfig.default_timeout_seconds()
    seconds * 1000
  end
end
