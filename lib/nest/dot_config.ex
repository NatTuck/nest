defmodule Nest.DotConfig do
  @moduledoc """
  Loads and manages XDG-compliant configuration from ~/.config/nest/config.toml
  """

  @config_dir :filename.basedir(:user_config, "nest")
  @config_file Path.join(@config_dir, "config.toml")

  # Default LLM call timeout, in seconds. LLM responses can be slow (large
  # prompts, complex tool use), so we default to a generous 5 minutes. Each
  # provider can override this via the `timeout` key in config.toml.
  @default_timeout_seconds 300

  # Default cap on consecutive tool-call iterations per agent chat turn.
  # Override with the top-level `max-tool-iterations` key in config.toml.
  @default_max_tool_iterations 25

  defmodule Provider do
    @moduledoc """
    Provider configuration struct.

    `timeout_seconds` is the per-provider LLM call receive timeout. Defaults
    to `Nest.DotConfig.@default_timeout_seconds` (300s = 5 minutes) if not
    set in the config file.
    """
    defstruct [
      :name,
      :base_url,
      :api_key,
      :protocol,
      :auto_models,
      :tags,
      :models,
      :timeout_seconds
    ]
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
  Returns the default LLM call timeout in seconds. Used when a provider
  has no explicit `timeout` configured.
  """
  def default_timeout_seconds, do: @default_timeout_seconds

  @doc """
  Returns the full path to config.toml
  """
  def config_file, do: @config_file

  @doc """
  Loads and parses the config file, returning a map with providers and models.
  In test environment, loads from test/data/config.toml instead of the default location.
  """
  def load do
    config_file =
      if Mix.env() == :test do
        Path.join([File.cwd!(), "test", "data", "config.toml"])
      else
        @config_file
      end

    load(config_file)
  end

  @doc """
  Loads config from a specific file path
  """
  def load(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, config} ->
            {:ok, parse_config(config)}

          {:error, reason} ->
            {:error, "Failed to parse TOML: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:error, "Config file not found at #{file_path}"}

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
  Returns the configured `max-tool-iterations` value, or `nil` when unset.
  Callers should fall back to `default_max_tool_iterations/0` when this
  returns `nil`.
  """
  def max_tool_iterations(config) do
    Map.get(config, :max_tool_iterations)
  end

  @doc """
  Returns the hardcoded fallback for the `max-tool-iterations` setting,
  used when config.toml does not specify a value.
  """
  def default_max_tool_iterations, do: @default_max_tool_iterations

  @doc """
  Resolve API key value (handles env var substitution)
  """
  def resolve_api_key(key_value) do
    cond do
      is_nil(key_value) ->
        nil

      env_var_match?(key_value) ->
        resolve_env_var(key_value)

      file_match?(key_value) ->
        resolve_file_key(key_value)

      true ->
        key_value
    end
  end

  defp env_var_match?(key_value) do
    String.starts_with?(key_value, "${") and String.ends_with?(key_value, "}")
  end

  defp resolve_env_var(key_value) do
    var_name = key_value |> String.slice(2..-2//1)

    case System.get_env(var_name) do
      nil -> raise "Environment variable #{var_name} not set"
      value -> value
    end
  end

  defp file_match?(key_value) do
    String.starts_with?(key_value, "file:")
  end

  defp resolve_file_key(key_value) do
    path = String.slice(key_value, 5..-1//1)
    expanded_path = Path.expand(path)

    case File.read(expanded_path) do
      {:ok, content} -> String.trim(content)
      {:error, reason} -> raise "Failed to read API key file #{path}: #{inspect(reason)}"
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
      models: models,
      max_tool_iterations: parse_max_tool_iterations(Map.get(raw_config, "max-tool-iterations"))
    }
  end

  # Parses and validates the top-level `max-tool-iterations` setting.
  # Returns `nil` when absent. Raises on invalid values so config errors
  # surface at startup, not on the first chat turn.
  defp parse_max_tool_iterations(nil), do: nil

  defp parse_max_tool_iterations(n) when is_integer(n) and n > 0, do: n

  defp parse_max_tool_iterations(other) do
    raise "Invalid max-tool-iterations #{inspect(other)}: must be a positive integer"
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
      models: models,
      timeout_seconds: parse_timeout(Map.get(data, "timeout"), name)
    }
  end

  # Parses and validates the optional `timeout` (in seconds) for a provider.
  # Returns the default if the key is absent. Raises on invalid values so
  # config errors surface at startup, not on the first LLM call.
  defp parse_timeout(nil, _provider_name), do: @default_timeout_seconds

  defp parse_timeout(seconds, _provider_name) when is_integer(seconds) and seconds > 0 do
    seconds
  end

  defp parse_timeout(seconds, provider_name) do
    raise "Provider #{provider_name}: invalid timeout #{inspect(seconds)}: must be a positive integer (seconds)"
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
