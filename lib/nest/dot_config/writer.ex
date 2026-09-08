defmodule Nest.DotConfig.Writer do
  @moduledoc """
  Serializes the configured `Nest.DotConfig.Provider` structs back to TOML
  and writes them to `local.toml` (the in-app editable overlay). `config.toml`
  is never written by the app.

  The written file is the full provider set the user manages; on load,
  `local.toml`'s `providers` table is authoritative over `config.toml`.
  """

  alias Nest.DotConfig
  alias Nest.DotConfig.Model
  alias Nest.DotConfig.Provider

  @doc """
  Write the given provider structs to `local.toml`. Returns `:ok` on
  success or `{:error, reason}` on failure.
  """
  @spec save_providers([Provider.t()]) :: :ok | {:error, term()}
  def save_providers(providers) do
    save_providers(providers, DotConfig.local_file())
  end

  @doc """
  Write the given provider structs to a specific file (test seam).
  """
  @spec save_providers([Provider.t()], String.t()) :: :ok | {:error, term()}
  def save_providers(providers, file) do
    config = %{
      "providers" => Map.new(providers, fn p -> {p.name, provider_to_map(p)} end)
    }

    with {:ok, toml} <- TomlElixir.encode(config),
         :ok <- File.mkdir_p(Path.dirname(file)) do
      File.write(file, toml)
    end
  end

  defp provider_to_map(%Provider{} = p) do
    %{}
    |> maybe_put("base-url", p.base_url)
    |> maybe_put("api-key", p.api_key)
    |> maybe_put("protocol", p.protocol)
    |> maybe_put("auto-models", p.auto_models)
    |> maybe_put("tags", p.tags)
    |> maybe_put("timeout", p.timeout_seconds)
    |> maybe_put("default-context-limit", p.default_context_limit)
    |> maybe_put("default-thinking-effort", effort_to_string(p.default_thinking_effort))
    |> maybe_put("probe-base-url", p.probe_base_url)
    |> maybe_put("auto-probe", p.auto_probe)
    |> maybe_put("expose-models", p.expose_models)
    |> maybe_put("models", Enum.map(p.models || [], &model_to_map/1))
  end

  defp model_to_map(%Model{} = m) do
    %{"name" => m.name}
    |> maybe_put("context-limit", m.context_limit)
    |> maybe_put("multi-modal", m.multi_modal)
    |> maybe_put("thinking-effort", effort_to_string(m.thinking_effort))
  end

  defp effort_to_string(nil), do: nil
  defp effort_to_string(effort), do: Atom.to_string(effort)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
