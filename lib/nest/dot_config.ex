defmodule Nest.DotConfig do
  @moduledoc """
  Loads and manages XDG-compliant configuration from ~/.config/nest/config.toml
  """

  @config_dir :filename.basedir(:user_config, "nest")
  @config_file Path.join(@config_dir, "config.toml")

  defmodule Provider do
    @moduledoc "Provider configuration struct"
    defstruct [:name, :base_url, :api_key, :protocol, :auto_models, :tags, :models]
  end

  defmodule Model do
    @moduledoc "Model configuration struct"
    defstruct [:name, :provider_name, :context_limit, :multi_modal]
  end

  @doc """
  Returns the XDG config directory path
  """
  def config_dir, do: @config_dir

  @doc """
  Returns the full path to config.toml
  """
  def config_file, do: @config_file

  @doc """
  Loads and parses the config file, returning a map with providers and models
  """
  def load do
    case File.read(@config_file) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, config} ->
            {:ok, parse_config(config)}

          {:error, reason} ->
            {:error, "Failed to parse TOML: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:error, "Config file not found at #{@config_file}"}

      {:error, reason} ->
        {:error, "Failed to read config: #{inspect(reason)}"}
    end
  end

  @doc """
  Loads config and returns providers map, or raises on error
  """
  def load! do
    case load() do
      {:ok, config} -> config
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Get a provider by name
  """
  def get_provider(config, name) when is_binary(name) do
    Map.get(config.providers, name)
  end

  def get_provider(config, name) when is_atom(name) do
    get_provider(config, to_string(name))
  end

  @doc """
  Find providers by tag
  """
  def get_providers_by_tag(config, tag) do
    config.providers
    |> Map.values()
    |> Enum.filter(fn provider ->
      Enum.member?(provider.tags || [], tag)
    end)
  end

  @doc """
  Get a model by name (searches across all providers)
  """
  def get_model(config, model_name) do
    case Map.get(config.models, model_name) do
      nil -> nil
      model -> model
    end
  end

  @doc """
  Find model by name within a specific provider
  """
  def get_model_by_provider(config, provider_name, model_name) do
    provider = get_provider(config, provider_name)

    if provider do
      Enum.find(provider.models || [], fn model ->
        model.name == model_name
      end)
    end
  end

  @doc """
  Resolve API key value (handles env var substitution)
  """
  def resolve_api_key(key_value) do
    cond do
      is_nil(key_value) ->
        nil

      String.starts_with?(key_value, "${") and String.ends_with?(key_value, "}") ->
        var_name = key_value |> String.slice(2..-2//1)

        case System.get_env(var_name) do
          nil -> raise "Environment variable #{var_name} not set"
          value -> value
        end

      String.starts_with?(key_value, "file:") ->
        path = String.slice(key_value, 5..-1//1)
        expanded_path = Path.expand(path)

        case File.read(expanded_path) do
          {:ok, content} -> String.trim(content)
          {:error, reason} -> raise "Failed to read API key file #{path}: #{inspect(reason)}"
        end

      true ->
        key_value
    end
  end

  # Private functions

  defp parse_config(raw_config) do
    providers =
      raw_config
      |> Map.get("providers", %{})
      |> Enum.map(fn {name, provider_data} ->
        {name, parse_provider(name, provider_data)}
      end)
      |> Map.new()

    # Build a flat models map for easy lookup
    models =
      providers
      |> Enum.flat_map(fn {provider_name, provider} ->
        (provider.models || [])
        |> Enum.map(fn model ->
          {model.name, %{model | provider_name: provider_name}}
        end)
      end)
      |> Map.new()

    %{
      providers: providers,
      models: models
    }
  end

  defp parse_provider(name, data) do
    models =
      case Map.get(data, "models") do
        nil ->
          []

        models_list when is_list(models_list) ->
          Enum.map(models_list, &parse_model/1)

        _other ->
          []
      end

    %Provider{
      name: name,
      base_url: Map.get(data, "base-url"),
      api_key: Map.get(data, "api-key"),
      protocol: Map.get(data, "protocol", "openai"),
      auto_models: Map.get(data, "auto-models", false),
      tags: Map.get(data, "tags", []),
      models: models
    }
  end

  defp parse_model(model_data) do
    multi_modal =
      case Map.get(model_data, "multi-modal") do
        nil -> nil
        mm when is_map(mm) -> mm
        _ -> nil
      end

    %Model{
      name: Map.get(model_data, "name"),
      provider_name: nil,
      context_limit: Map.get(model_data, "context-limit"),
      multi_modal: multi_modal
    }
  end
end
