defmodule Nest.Models.Catalog do
  @moduledoc """
  Builds the merged model-list payload (`Nest.Models.list/0`'s shape)
  from a `Nest.Models` state map.

  Pure: it reads the state's `static_config`, `auto_models`,
  `context_limits`, and `scan` fields and returns the JSON-safe list of
  model maps. Extracted from `Nest.Models` to keep that module under
  the source-file line cap; the GenServer still owns the state and
  calls this to answer `list/0` and to build every PubSub payload.
  """

  alias Nest.Models.MultiModal

  @doc """
  The merged model list for `state`. Static config wins over
  auto-discovery on name collisions. The `context_limit` returned per
  entry is the *effective* value resolved across the three layers in
  priority order:

    1. Per-model static `context-limit` (already on the merged
       `DotConfig.Model` struct when present in TOML)
    2. Auto-discovery cache (per-{provider, model_id})
    3. Provider-level `default-context-limit`

  Computed at read time so a `reload_static/0` takes effect
  immediately on the next read without forcing a refresh.
  """
  @spec build(map()) :: [map()]
  def build(state) do
    {auto, cache} = scan_view(state)
    providers = (state.static_config && state.static_config.providers) || %{}
    static = static_models(state)

    Map.merge(auto, static)
    |> Map.values()
    |> Enum.map(fn model ->
      %{
        "name" => model.name,
        "provider" => model.provider_name,
        "context_limit" => effective_context_limit(model, cache, providers),
        "multi_modal" => effective_multi_modal(model, auto),
        "thinking_levels" => thinking_levels()
      }
    end)
  end

  # While a scan is active, `state.auto_models`/`state.context_limits`
  # still hold the previous scan's completed values. Read from the
  # in-flight accumulator so partial results are visible; fall back
  # to the canonical fields when idle.
  defp scan_view(%{scan: %{auto_models: auto, context_limits: limits}}), do: {auto, limits}
  defp scan_view(state), do: {state.auto_models, state.context_limits}

  defp static_models(%{static_config: %{models: static}}) when is_map(static), do: static
  defp static_models(_state), do: %{}

  # The thinking levels a model can be configured with. Phase 1
  # exposes the full supported set for every model; narrowing per
  # model from provider capability discovery is future work.
  defp thinking_levels do
    Nest.DotConfig.thinking_efforts()
    |> Enum.map(&to_string/1)
  end

  defp effective_context_limit(model, cache, providers) do
    cond do
      is_integer(model.context_limit) ->
        model.context_limit

      limit = get_in(cache, [model.provider_name, model.name]) ->
        case limit do
          {_source, n} when is_integer(n) -> n
          _ -> provider_default(providers, model.provider_name)
        end

      true ->
        provider_default(providers, model.provider_name)
    end
  end

  # The multi-modal input vocabulary for a merged model entry. An
  # explicit static `multi-modal` is authoritative and is never
  # overwritten by a differing discovery answer; detection is a
  # fill-in for when static config sets nothing. See
  # `Nest.Models.MultiModal.effective/2` for the {provider, name}
  # matching rule.
  defp effective_multi_modal(model, auto), do: MultiModal.effective(model, auto)

  defp provider_default(providers, provider_name) do
    case Map.get(providers, provider_name) do
      %{default_context_limit: limit} when is_integer(limit) -> limit
      _ -> nil
    end
  end
end
