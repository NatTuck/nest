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
end
