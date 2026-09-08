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
  @default_max_tool_iterations 99

  # Default maximum depth for agent delegation (sub-agents).
  # Override with the top-level `max-depth` key in config.toml.
  @default_max_depth 3

  # Supported thinking levels (reasoning effort) a model can be
  # configured with. `:off` disables thinking; the rest are ascending
  # effort levels. `:xhigh` is Anthropic-only (OpenAI-compatible
  # servers map it to `high`). The global default is `:medium`.
  @thinking_efforts [:off, :low, :medium, :high, :xhigh]
  @thinking_effort_strings %{
    "off" => :off,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "xhigh" => :xhigh
  }
  @default_thinking_effort :medium

  defmodule Provider do
    @moduledoc """
    Provider configuration struct.

    `timeout_seconds` is the per-provider LLM call receive timeout. Defaults
    to `Nest.DotConfig.@default_timeout_seconds` (300s = 5 minutes) if not
    set in the config file.

    `default_context_limit` is the optional provider-wide fallback for
    `context-window` size, used when neither the per-model
    `[[providers.<name>.models]]` block nor the auto-discovery cache
    carries a value. Parsed from the optional `default-context-limit`
    TOML key on `[providers.<name>]`. `nil` when absent.

    `rewrite_late_system_messages` is the optional boolean that routes
    mid-conversation reminders (context-usage threshold, tool-call
    budget, the compactor's `[mode: compact]` suffix) through `User`
    messages with `[System notice: …]` brackets instead of `System`
    messages. Defaults to `false`. Set on providers whose chat
    template enforces "system must be at the beginning" (Qwen3.5 on
    vLLM, etc.). Parsed from the optional `rewrite-late-system-messages`
    TOML key. See `Nest.Agents.Agent.ChatTurn.LateMessage.build/2`.

    `probe_base_url` is the optional URL used for *model discovery*
    only (`GET <base>/models`). Defaults to `nil`, in which case
    `base_url` is used for both chat and discovery. Set this on
    providers whose chat base and discovery base diverge — e.g. an
    Olla-style discovery listing at one path and OpenAI-compatible
    chat at another. Parsed from the optional `probe-base-url`
    TOML key. See `Nest.LLM.Discover` and `Nest.ChatModel`.

    `auto_probe` is the optional flag that enables endpoint probing
    (`Nest.EndpointProbe` + `Nest.EndpointCache`) for this provider.
    Defaults to `true`. When enabled, the chat protocol, chat base
    URL, and discovery `/models` path are auto-detected at startup
    and re-detected when a cached endpoint starts returning `404`.
    Set `auto-probe = false` on a provider you'd rather configure
    fully by hand. Parsed from the optional `auto-probe` TOML key.

    `expose_models` is the optional flag that makes this provider's
    models visible in the `models-list` tool output. Defaults to
    `false`. Set `expose-models = true` on providers whose models
    should be discoverable by agents via the `models-list` tool.
    """
    defstruct [
      :name,
      :base_url,
      :api_key,
      :protocol,
      :auto_models,
      :tags,
      :models,
      :timeout_seconds,
      :default_context_limit,
      :default_thinking_effort,
      :probe_base_url,
      :expose_models,
      auto_probe: true
    ]
  end

  defmodule Model do
    @moduledoc "Model configuration struct"
    defstruct [
      :name,
      :provider_name,
      :context_limit,
      :multi_modal,
      :thinking_effort
    ]
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
  Returns the full path to local.toml — the user's overlay config edited
  from the in-app Providers screen. `local.toml` is merged over
  `config.toml` (local wins per provider); `config.toml` is never
  modified by the app.

  The path can be overridden for testing via the application env
  key `:local_config_file`.
  """
  def local_file do
    case Application.get_env(:nest, :local_config_file) do
      nil -> default_local_file()
      path -> path
    end
  end

  defp default_local_file do
    if Mix.env() == :test do
      Path.join([File.cwd!(), "test", "data", "local.toml"])
    else
      Path.join(@config_dir, "local.toml")
    end
  end

  @doc """
  Loads and parses the config file, returning a map with providers and models.
  In test environment, loads from test/data/config.toml instead of the default location.

  The user's `local.toml` (if present) is merged over `config.toml`:
  providers/models defined in `local.toml` override the same-named entries
  in `config.toml`, and top-level scalars from `local.toml` win.
  """
  def load do
    base =
      if Mix.env() == :test do
        Path.join([File.cwd!(), "test", "data", "config.toml"])
      else
        @config_file
      end

    merge_loads(load(base), load(local_file()))
  end

  # Merge the base (config.toml) and overlay (local.toml) parses. Missing
  # files are treated as empty. Local wins at provider/model and top-level
  # key granularity.
  defp merge_loads({:ok, base}, {:ok, local}) do
    {:ok, merge_configs(base, local)}
  end

  defp merge_loads({:ok, base}, {:error, _}), do: {:ok, base}
  defp merge_loads({:error, reason}, _local), do: {:error, reason}

  defp merge_configs(base, local) do
    # `local.toml` is the authoritative provider list when it defines one
    # (the app always writes the full set it manages), so a provider
    # deleted from the GUI actually disappears rather than being
    # re-added from `config.toml`. Other top-level scalars merge with
    # local winning per key.
    providers =
      if map_size(local.providers) > 0, do: local.providers, else: base.providers

    models =
      providers
      |> Map.values()
      |> Enum.flat_map(fn p ->
        (p.models || []) |> Enum.map(&%{&1 | provider_name: p.name})
      end)
      |> Map.new(fn m -> {m.name, m} end)

    %{
      base
      | providers: providers,
        models: models,
        max_tool_iterations: local.max_tool_iterations || base.max_tool_iterations,
        max_depth: local.max_depth || base.max_depth,
        default_thinking_effort: local.default_thinking_effort || base.default_thinking_effort
    }
  end

  @doc """
  Loads config from a specific file path. The parsed result is cached
  per `{file_path, mtime}` so repeated loads (e.g. per agent spawn) don't
  re-read + re-parse the file; the cache invalidates automatically when
  the file's mtime changes.
  """
  def load(file_path) do
    case cached_config(file_path) do
      {:ok, config} ->
        {:ok, config}

      :miss ->
        do_load(file_path)
    end
  end

  defp do_load(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, config} ->
            config = parse_config(config)
            cache_config(file_path, config)
            {:ok, config}

          {:error, reason} ->
            {:error, "Failed to parse TOML: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:error, "Config file not found at #{file_path}"}

      {:error, reason} ->
        {:error, "Failed to read config: #{inspect(reason)}"}
    end
  end

  @cache_table :nest_dotconfig_cache

  defp cache_table do
    case :ets.whereis(@cache_table) do
      :undefined -> :ets.new(@cache_table, [:named_table, :public, read_concurrency: true])
      _ -> @cache_table
    end
  end

  defp cached_config(path) do
    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         [{_, config}] <- :ets.lookup(cache_table(), {path, mtime}) do
      {:ok, config}
    else
      _ -> :miss
    end
  end

  defp cache_config(path, config) do
    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix) do
      :ets.insert(cache_table(), {{path, mtime}, config})
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
  # Configured `max-tool-iterations` (nil → caller falls back to
  # `default_max_tool_iterations/0`).
  def max_tool_iterations(config), do: Map.get(config, :max_tool_iterations)

  # Hardcoded fallback for `max-tool-iterations`.
  def default_max_tool_iterations, do: @default_max_tool_iterations

  # Configured `max-depth` (nil → caller falls back to
  # `default_max_depth/0`).
  def max_depth(config), do: Map.get(config, :max_depth)

  @doc """
  Returns the hardcoded fallback for the `max-depth` setting.
  """
  def default_max_depth, do: @default_max_depth

  # Configured top-level `default-thinking-effort` (nil → caller falls
  # back to `default_thinking_effort/0`).
  def default_thinking_effort(config), do: Map.get(config, :default_thinking_effort)

  @doc """
  Returns the hardcoded fallback thinking level (`:medium`).
  """
  def default_thinking_effort, do: @default_thinking_effort

  @doc """
  Normalize a thinking-effort config value (string or atom) to the
  canonical atom. Returns `nil` for `nil`. Raises on unknown values so
  a config typo surfaces at load, not on the first LLM call.
  """
  @spec parse_thinking_effort(term()) :: atom() | nil
  def parse_thinking_effort(nil), do: nil
  def parse_thinking_effort(value) when value in @thinking_efforts, do: value

  def parse_thinking_effort(value) when is_binary(value),
    do: Map.get(@thinking_effort_strings, value) || invalid_thinking_effort!(value)

  def parse_thinking_effort(value), do: invalid_thinking_effort!(value)

  defp invalid_thinking_effort!(value) do
    raise "Invalid thinking-effort #{inspect(value)}: must be one of " <>
            Enum.map_join(@thinking_efforts, "/", &to_string/1)
  end

  @doc """
  All supported thinking levels, in ascending effort order.
  """
  def thinking_efforts, do: @thinking_efforts

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

  defp env_var_match?(key_value),
    do: String.starts_with?(key_value, "${") and String.ends_with?(key_value, "}")

  defp resolve_env_var(key_value) do
    case System.get_env(String.slice(key_value, 2..-2//1)) do
      nil -> raise "Environment variable #{key_value} not set"
      value -> value
    end
  end

  defp file_match?(key_value), do: String.starts_with?(key_value, "file:")

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
      max_tool_iterations: parse_max_tool_iterations(Map.get(raw_config, "max-tool-iterations")),
      max_depth: parse_max_depth(Map.get(raw_config, "max-depth")),
      default_thinking_effort:
        parse_thinking_effort(Map.get(raw_config, "default-thinking-effort"))
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

  # Parses and validates the top-level `max-depth` setting.
  # Returns `nil` when absent. Raises on invalid values so config errors
  # surface at startup, not on the first delegation attempt.
  defp parse_max_depth(nil), do: nil

  defp parse_max_depth(n) when is_integer(n) and n > 0, do: n

  defp parse_max_depth(other) do
    raise "Invalid max-depth #{inspect(other)}: must be a positive integer"
  end

  defp parse_provider(name, data) do
    %Provider{
      name: name,
      base_url: Map.get(data, "base-url"),
      api_key: Map.get(data, "api-key"),
      protocol: Map.get(data, "protocol", "openai"),
      auto_models: Map.get(data, "auto-models", false),
      tags: Map.get(data, "tags", []),
      models: parse_provider_models(data),
      timeout_seconds: parse_timeout(Map.get(data, "timeout"), name),
      default_context_limit:
        parse_default_context_limit(Map.get(data, "default-context-limit"), name),
      default_thinking_effort: parse_thinking_effort(Map.get(data, "default-thinking-effort")),
      probe_base_url: parse_probe_base_url(Map.get(data, "probe-base-url"), name),
      auto_probe: parse_auto_probe(Map.get(data, "auto-probe"), name),
      expose_models: parse_expose_models(Map.get(data, "expose-models"), name)
    }
  end

  # Parses the provider's explicit `models` list, returning `[]`
  # when the key is absent or malformed.
  defp parse_provider_models(data) do
    case Map.get(data, "models") do
      models_list when is_list(models_list) -> Enum.map(models_list, &parse_model/1)
      _ -> []
    end
  end

  # Parses the optional `probe-base-url` (a discovery-only URL) for
  # a provider. `nil` when absent (the default — discovery then
  # reuses `base_url`). The schema is "any non-empty binary"; we
  # keep validation lightweight because the URL is dereferenced
  # lazily on the first probe. A typo at config-write time will
  # surface as a probe HTTP error rather than a startup crash, but
  # `parse_default_context_limit`'s stricter convention (raise on
  # nonsense) doesn't fit here — the URL is a string, not a number.
  defp parse_probe_base_url(nil, _provider_name), do: nil

  defp parse_probe_base_url(url, _provider_name) when is_binary(url) and url != "",
    do: url

  defp parse_probe_base_url(value, provider_name) do
    raise "Provider #{provider_name}: invalid probe-base-url #{inspect(value)}: must be a non-empty string"
  end

  # Parses the optional `auto-probe` flag (endpoint auto-detection).
  # Defaults to `true` when absent.
  defp parse_auto_probe(nil, _provider_name), do: true

  defp parse_auto_probe(value, _provider_name) when is_boolean(value), do: value

  defp parse_auto_probe(value, provider_name) do
    raise "Provider #{provider_name}: invalid auto-probe #{inspect(value)}: must be a boolean"
  end

  # Parses the optional `expose-models` flag (model visibility in models-list).
  # Defaults to `false` when absent.
  defp parse_expose_models(nil, _provider_name), do: false

  defp parse_expose_models(value, _provider_name) when is_boolean(value), do: value

  defp parse_expose_models(value, provider_name) do
    raise "Provider #{provider_name}: invalid expose-models #{inspect(value)}: must be a boolean"
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

  # Parses and validates the optional `default-context-limit` for a
  # provider. Returns `nil` when the key is absent (no provider-wide
  # fallback). Raises on invalid values so config errors surface at
  # startup, not on the first chat turn.
  defp parse_default_context_limit(nil, _provider_name), do: nil

  defp parse_default_context_limit(limit, _provider_name)
       when is_integer(limit) and limit > 0 do
    limit
  end

  defp parse_default_context_limit(limit, provider_name) do
    raise "Provider #{provider_name}: invalid default-context-limit #{inspect(limit)}: must be a positive integer"
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
      multi_modal: multi_modal,
      thinking_effort: parse_thinking_effort(Map.get(model_data, "thinking-effort"))
    }
  end
end
