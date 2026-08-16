defmodule Nest.Agents.Agent.Config do
  @moduledoc """
  Config-derived helpers for the agent. Extracted from
  `Nest.Agents.Agent` to keep the GenServer module under
  the credo line limit.

  Owns three concerns:

    * `create_client_config/1` — build a `ClientConfig` from
      the user's model attribute.
    * `configured_context_limit/1` — read the optional
      `context-limit` value for a model from DotConfig.
    * `configured_max_tool_iterations/0` — read the optional
      `max-tool-iterations` value from DotConfig.

  All three are pure functions (or pure reads of DotConfig
  on disk). None of them mutate Agent state.
  """

  alias Nest.ChatModel
  alias Nest.DotConfig
  alias Nest.LLM.ClientConfig

  @doc """
  Build a `ClientConfig` from the user's model attribute.
  Returns `{:error, :no_model_name}` if the attribute is
  missing the required `:name` (or `"name"`) key.
  """
  @spec create_client_config(map()) :: {:ok, ClientConfig.t()} | {:error, :no_model_name}
  def create_client_config(model) do
    model_name = model[:name] || model["name"]

    if model_name do
      ChatModel.new(model: model_name)
    else
      {:error, :no_model_name}
    end
  end

  @doc """
  Look up the user-configured `context-limit` for this model
  in DotConfig. Returns `nil` when absent so the caller can
  decide whether to fall through to the probe.
  """
  @spec configured_context_limit(String.t() | nil) :: non_neg_integer() | nil
  def configured_context_limit(nil), do: nil

  def configured_context_limit(model_name) when is_binary(model_name) do
    case DotConfig.load() do
      {:ok, config} ->
        case DotConfig.get_model(config, model_name) do
          nil -> nil
          model -> model.context_limit
        end

      _ ->
        nil
    end
  end

  @doc """
  Look up the provider-wide `default-context-limit` for this
  provider in DotConfig. Returns `nil` when absent so the caller
  can decide whether to fall through to `nil`.

  Used by the agent's context-limit resolution chain as a
  fallback when neither the per-model `context-limit` nor the
  auto-discovery cache has a value.
  """
  @spec configured_provider_default_context_limit(String.t() | nil) :: non_neg_integer() | nil
  def configured_provider_default_context_limit(nil), do: nil

  def configured_provider_default_context_limit(provider_name) when is_binary(provider_name) do
    case DotConfig.load() do
      {:ok, config} ->
        case DotConfig.get_provider(config, provider_name) do
          nil -> nil
          provider -> provider.default_context_limit
        end

      _ ->
        nil
    end
  end

  @doc """
  Resolve the per-chat tool-call iteration cap. Reads the
  optional top-level `max-tool-iterations` value from
  DotConfig; falls back to `DotConfig.default_max_tool_iterations/0`
  (25) when unset.
  """
  @spec configured_max_tool_iterations() :: pos_integer()
  def configured_max_tool_iterations do
    case DotConfig.load() do
      {:ok, config} ->
        case DotConfig.max_tool_iterations(config) do
          nil -> DotConfig.default_max_tool_iterations()
          n -> n
        end

      _ ->
        DotConfig.default_max_tool_iterations()
    end
  end

  @doc """
  Resolve the per-tree delegation depth cap. Reads the
  optional top-level `max-depth` value from DotConfig;
  falls back to `DotConfig.default_max_depth/0` (3) when
  unset.

  Used by the spawn path to reject spawns at max depth, by
  the compaction path to drop `agents-spawn` for a
  max-depth agent, and by `SystemPrompt`'s identity line
  (which reports the agent's depth of this cap).
  """
  @spec configured_max_depth() :: pos_integer()
  def configured_max_depth do
    case DotConfig.load() do
      {:ok, config} ->
        case DotConfig.max_depth(config) do
          nil -> DotConfig.default_max_depth()
          n -> n
        end

      _ ->
        DotConfig.default_max_depth()
    end
  end
end
