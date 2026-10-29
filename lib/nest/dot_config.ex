defmodule Nest.DotConfig do
  @moduledoc """
  Loads and manages XDG-compliant configuration from ~/.config/nest/config.toml
  """

  alias Nest.DotConfig.FieldValidation
  alias Nest.DotConfig.KeyValidation
  alias Nest.DotConfig.Model
  alias Nest.DotConfig.ModelValidation
  alias Nest.DotConfig.Provider
  alias Nest.ParseCache

  @config_dir :filename.basedir(:user_config, "nest")
  @config_file Path.join(@config_dir, "config.toml")

  # Default bound on silence *before the first streamed chunk*, in seconds.
  # A long-context cache miss has to prefill the whole prompt before it can
  # emit anything, and the provider may queue the request first, so this is
  # the one bound that has to be generous: 15 minutes.
  @default_first_byte_timeout_seconds 900

  # Default bound on silence *between* chunks once the stream has started, in
  # seconds. Once the provider is streaming, a two-minute gap is a dead
  # connection, not a slow prefill — and this is the bound that decides how
  # quickly a hang is noticed and retried.
  @default_stream_idle_timeout_seconds 120

  # Default cap on consecutive tool-call iterations per agent chat turn.
  # Override with the top-level `max-tool-iterations` key in config.toml.
  @default_max_tool_iterations 99

  # Default maximum depth for agent delegation (sub-agents).
  # Override with the top-level `max-depth` key in config.toml.
  @default_max_depth 3

  # Default maximum number of sub-agents `agents-batch` call runs
  # concurrently. Override with the top-level `max-concurrency` key in
  # config.toml.
  @default_max_concurrency 4

  # Default inline token cap for the combined async inbox message
  # (`agents-send`). When the combined queued messages exceed this, the
  # full text is written to the agent's scratch dir and the agent is
  # told the message count and the file path instead. Override with the
  # top-level `max-async-message-tokens` key in config.toml.
  @default_max_async_message_tokens 8_000

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

  @doc """
  Returns the XDG config directory path
  """
  def config_dir, do: @config_dir

  @doc """
  Returns the default first-byte timeout in seconds. Used when a provider
  has no explicit `first_byte_timeout` (or legacy `timeout`) configured.
  """
  def default_first_byte_timeout_seconds, do: @default_first_byte_timeout_seconds

  @doc """
  Returns the default stream idle timeout in seconds. Used when a provider
  has no explicit `stream_idle_timeout` configured.
  """
  def default_stream_idle_timeout_seconds, do: @default_stream_idle_timeout_seconds

  @doc """
  Returns the full path to local.toml — the user's overlay config edited
  from the in-app Providers screen. `local.toml` is merged over
  `config.toml` (local wins per provider); `config.toml` is never
  modified by the app.
  """
  def local_file, do: default_local_file()

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

    # `__MODULE__.local_file()` is a remote self-call on purpose: Mimic
    # copies `Nest.DotConfig` by renaming the original to
    # `Nest.DotConfig.Mimic.Original.Module` and installing a proxy under
    # `Nest.DotConfig`. A bare local `local_file()` would bind to the
    # renamed original and bypass the proxy, so this *internal* read of
    # `load/0` would ignore the `Mimic.stub(Nest.DotConfig, :local_file, ...)`
    # that `lobby_channel/providers_test.exs` sets and silently fall back to
    # `config.toml` (`test/data/local.toml` does not exist). The writer is
    # unaffected: `dot_config/writer.ex` reaches the proxy through its own
    # remote `DotConfig.local_file()`. This relies on `local_file/0` staying
    # public — private is a loud compile warning (an error under
    # `--warnings-as-errors`), but dropping the `__MODULE__.` prefix is a
    # silent re-break of that test.
    merge_loads(load(base), load(__MODULE__.local_file()))
    # `&resolve_api_key/1` is a local capture on purpose: `Nest.DotConfig` is
    # Mimic-wrapped, so a remote `__MODULE__.resolve_api_key/1` would go
    # through the proxy and pick up any stub. See `KeyValidation`.
    |> KeyValidation.validate(&resolve_api_key/1)
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
        max_concurrency: local.max_concurrency || base.max_concurrency,
        max_async_message_tokens: local.max_async_message_tokens || base.max_async_message_tokens,
        default_thinking_effort: local.default_thinking_effort || base.default_thinking_effort
    }
  end

  @doc """
  Loads config from a specific file path.

  The file is read on every call, because that read is how a change is noticed.
  Only the expensive half — the TOML decode and the parse — is cached, keyed on
  the bytes that were read (`Nest.ParseCache`). Repeated loads of an
  unchanged file (e.g. one per agent spawn) therefore re-read it but never
  re-parse it, and a file that changed at all is re-parsed, whoever wrote it.
  """
  def load(file_path) do
    with {:ok, content} <- read(file_path) do
      case ParseCache.fetch(file_path, content) do
        {:ok, config} -> {:ok, config}
        :miss -> decode(file_path, content)
      end
    end
  end

  defp read(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, "Config file not found at #{file_path}"}

      {:error, reason} ->
        {:error, "Failed to read config: #{inspect(reason)}"}
    end
  end

  defp decode(file_path, content) do
    case Toml.decode(content) do
      {:ok, config} ->
        config = parse_config(config)
        ParseCache.put(file_path, content, config)
        {:ok, config}

      {:error, reason} ->
        {:error, "Failed to parse TOML: #{inspect(reason)}"}
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

  # Configured `max-concurrency` (nil → caller falls back to
  # `default_max_concurrency/0`).
  def max_concurrency(config), do: Map.get(config, :max_concurrency)

  @doc """
  Returns the hardcoded fallback for the `max-concurrency` setting.
  """
  def default_max_concurrency, do: @default_max_concurrency

  # Configured `max-async-message-tokens` (nil → caller falls back to
  # `default_max_async_message_tokens/0`).
  def max_async_message_tokens(config), do: Map.get(config, :max_async_message_tokens)

  @doc """
  Returns the hardcoded fallback for the `max-async-message-tokens`
  setting (8000).
  """
  def default_max_async_message_tokens, do: @default_max_async_message_tokens

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

    Map.merge(
      %{providers: providers, models: models},
      parse_settings(raw_config)
    )
  end

  # Parse the top-level scalar settings. Kept separate from
  # `parse_config/1` so the provider/model construction and the scalar
  # parsing each stay under the credo ABC cap.
  defp parse_settings(raw_config) do
    %{
      max_tool_iterations: parse_max_tool_iterations(Map.get(raw_config, "max-tool-iterations")),
      max_depth: parse_max_depth(Map.get(raw_config, "max-depth")),
      max_concurrency: parse_max_concurrency(Map.get(raw_config, "max-concurrency")),
      max_async_message_tokens:
        parse_max_async_message_tokens(Map.get(raw_config, "max-async-message-tokens")),
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

  # Parses and validates the top-level `max-concurrency` setting.
  # Returns `nil` when absent. Raises on invalid values.
  defp parse_max_concurrency(nil), do: nil

  defp parse_max_concurrency(n) when is_integer(n) and n > 0, do: n

  defp parse_max_concurrency(other) do
    raise "Invalid max-concurrency #{inspect(other)}: must be a positive integer"
  end

  # Parses and validates the top-level `max-async-message-tokens`
  # setting. Returns `nil` when absent. Raises on invalid values.
  defp parse_max_async_message_tokens(nil), do: nil

  defp parse_max_async_message_tokens(n) when is_integer(n) and n > 0, do: n

  defp parse_max_async_message_tokens(other) do
    raise "Invalid max-async-message-tokens #{inspect(other)}: must be a positive integer"
  end

  defp parse_provider(name, data) do
    %Provider{
      name: name,
      base_url: ModelValidation.validate_base_url(Map.get(data, "base-url"), name),
      api_key: ModelValidation.validate_api_key(Map.get(data, "api-key"), name),
      protocol: Map.get(data, "protocol", "openai"),
      auto_models: Map.get(data, "auto-models", false),
      tags: parse_tags(Map.get(data, "tags"), name),
      models: parse_provider_models(data, name),
      first_byte_timeout_seconds: parse_first_byte_timeout(data, name),
      stream_idle_timeout_seconds: parse_stream_idle_timeout(data, name),
      default_context_limit:
        parse_default_context_limit(Map.get(data, "default-context-limit"), name),
      default_thinking_effort: parse_thinking_effort(Map.get(data, "default-thinking-effort")),
      probe_base_url: parse_probe_base_url(Map.get(data, "probe-base-url"), name),
      auto_probe: parse_auto_probe(Map.get(data, "auto-probe"), name),
      expose_models: parse_expose_models(Map.get(data, "expose-models"), name),
      probe_multimodal: parse_probe_multimodal(Map.get(data, "probe-multimodal"), name)
    }
  end

  # Parses the provider's explicit `models` list: absent means none, a list is
  # parsed, and anything else raises.
  #
  # A malformed value used to fall through to `[]`, silently dropping the whole
  # model list — the opposite of the "a bad value is a startup error" convention
  # the rest of this module follows. The write side already raised on it
  # (`Enum.map/2` on a non-list), so the two sides agree now.
  defp parse_provider_models(data, provider_name) do
    case Map.get(data, "models") do
      nil ->
        []

      models_list when is_list(models_list) ->
        Enum.map(models_list, &parse_model(&1, provider_name))

      other ->
        raise "Provider #{provider_name}: invalid models #{inspect(other)}: " <>
                "must be an array of tables"
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
  #
  # The rule is shared with the write side (`FieldValidation.non_empty_string`)
  # so the two cannot disagree: the write side used to pass this field through
  # unvalidated, so a `probe-base-url = ""` written from a channel client was
  # persisted and then raised here on the re-read — killing `Models`, and with it
  # the next boot.
  defp parse_probe_base_url(nil, _provider_name), do: nil

  defp parse_probe_base_url(url, provider_name),
    do: FieldValidation.non_empty_string(url, provider_name, "probe-base-url")

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

  # Parses the optional `probe-multimodal` opt-in (a discovered
  # model's image-input support may be probed by
  # `Nest.LLM.MultimodalProbe`). Defaults to `false` when absent:
  # probing costs a real request per model, so it is opt-in.
  defp parse_probe_multimodal(nil, _provider_name), do: false

  defp parse_probe_multimodal(value, _provider_name) when is_boolean(value), do: value

  defp parse_probe_multimodal(value, provider_name) do
    raise "Provider #{provider_name}: invalid probe-multimodal #{inspect(value)}: must be a boolean"
  end

  # Parses and validates the provider's first-byte bound (seconds). Returns the
  # default if neither key is present. Raises on invalid values so config
  # errors surface at startup, not on the first LLM call.
  #
  # `timeout` is the pre-split name for this bound and is still honoured: before
  # the split it was the *only* silence bound, so the silence it actually
  # defended against in practice was the prefill (a 350k-token cache miss), and
  # that is what it keeps meaning. It deliberately does not become the idle
  # bound — an existing `timeout = 600` must not make every dead connection take
  # ten minutes to notice.
  defp parse_first_byte_timeout(data, provider_name) do
    case Map.get(data, "first_byte_timeout") do
      nil ->
        case Map.get(data, "timeout") do
          nil -> @default_first_byte_timeout_seconds
          seconds -> ModelValidation.validate_timeout(seconds, provider_name)
        end

      seconds ->
        ModelValidation.validate_timeout(seconds, provider_name, "first_byte_timeout")
    end
  end

  # Parses and validates the provider's stream-idle bound (seconds). Returns the
  # default if the key is absent. Raises on invalid values so config errors
  # surface at startup, not on the first LLM call.
  defp parse_stream_idle_timeout(data, provider_name) do
    case Map.get(data, "stream_idle_timeout") do
      nil ->
        @default_stream_idle_timeout_seconds

      seconds ->
        ModelValidation.validate_timeout(seconds, provider_name, "stream_idle_timeout")
    end
  end

  # Parses and validates the optional `default-context-limit` for a
  # provider. Returns `nil` when the key is absent (no provider-wide
  # fallback). Raises on invalid values so config errors surface at
  # startup, not on the first chat turn.
  defp parse_default_context_limit(limit, provider_name),
    do: ModelValidation.validate_default_context_limit(limit, provider_name)

  # Parses and validates a provider's `tags`: absent means no tags, a list of
  # names is kept, and anything else raises. `tags = "abc"` used to reach
  # `Enum.member?/2` in `get_providers_by_tag/2`, which raises on a binary.
  defp parse_tags(nil, _provider_name), do: []

  defp parse_tags(tags, provider_name),
    do: ModelValidation.validate_tags(tags, provider_name)

  defp parse_model(model_data, provider_name) do
    name = ModelValidation.validate_name(Map.get(model_data, "name"), provider_name)

    %Model{
      name: name,
      provider_name: nil,
      context_limit:
        ModelValidation.validate_context_limit(
          Map.get(model_data, "context-limit"),
          provider_name,
          name
        ),
      multi_modal:
        ModelValidation.validate_multi_modal(
          Map.get(model_data, "multi-modal"),
          provider_name,
          name
        ),
      thinking_effort: parse_thinking_effort(Map.get(model_data, "thinking-effort"))
    }
  end
end
