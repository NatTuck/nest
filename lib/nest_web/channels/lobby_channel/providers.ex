defmodule NestWeb.LobbyChannel.Providers do
  @moduledoc """
  Provider-configuration `handle_in` handlers for the LobbyChannel,
  extracted so the parent module stays under the credo 500-line cap.

  `providers/0` serializes the configured `DotConfig.Provider` structs
  for the GUI (used in the lobby `init` payload and the
  `providers_updated` broadcast). `save/2` persists the provider set
  to `~/.config/nest/local.toml` (never `config.toml`), reloads the
  runtime model cache, and broadcasts the new list.

  Admin-only: callers must authorize `is_admin` before calling
  `save/2`.
  """

  alias Nest.DotConfig
  alias Nest.DotConfig.Model
  alias Nest.DotConfig.Provider
  alias Nest.DotConfig.Writer
  alias Nest.Models

  @doc """
  The configured providers, serialized for the GUI. Returns an empty
  list when the config can't be loaded.
  """
  @spec providers() :: [map()]
  def providers do
    case DotConfig.load() do
      {:ok, config} -> config.providers |> Map.values() |> Enum.map(&provider_to_map/1)
      _ -> []
    end
  end

  @doc """
  Persist the provider set (from the GUI payload) to `local.toml`,
  reload the runtime model cache, and broadcast `providers_updated` +
  `models_updated`. Returns `{:reply, :ok, socket}` on success.
  """
  @spec save(map(), Phoenix.Socket.t()) :: {:reply, term(), Phoenix.Socket.t()}
  def save(%{"providers" => providers} = _payload, socket) when is_list(providers) do
    # `provider_from_map/1` raises on an invalid payload (e.g. a bad
    # thinking-effort value); the function-level `rescue` turns that into
    # `invalid_payload`.
    structs = Enum.map(providers, &provider_from_map/1)

    case Writer.save_providers(structs) do
      :ok ->
        Models.reload_static()
        Models.refresh()
        Phoenix.Channel.broadcast(socket, "providers_updated", %{providers: providers()})
        {:reply, :ok, socket}

      {:error, _reason} ->
        {:reply, {:error, %{"reason" => "failed_to_save"}}, socket}
    end
  rescue
    _ -> {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
  end

  def save(_payload, socket) do
    {:reply, {:error, %{"reason" => "invalid_payload"}}, socket}
  end

  defp provider_to_map(%Provider{} = p) do
    %{
      "name" => p.name,
      "base_url" => p.base_url,
      "api_key" => p.api_key,
      "protocol" => p.protocol,
      "auto_models" => p.auto_models,
      "tags" => p.tags || [],
      "timeout_seconds" => p.timeout_seconds,
      "default_context_limit" => p.default_context_limit,
      "default_thinking_effort" => effort_to_string(p.default_thinking_effort),
      "probe_base_url" => p.probe_base_url,
      "auto_probe" => p.auto_probe,
      "models" => Enum.map(p.models || [], &model_to_map/1)
    }
  end

  defp model_to_map(%Model{} = m) do
    %{
      "name" => m.name,
      "context_limit" => m.context_limit,
      "multi_modal" => m.multi_modal,
      "thinking_effort" => effort_to_string(m.thinking_effort)
    }
  end

  defp provider_from_map(m) do
    %Provider{
      name: m["name"],
      base_url: m["base_url"],
      api_key: m["api_key"],
      protocol: m["protocol"] || "openai",
      auto_models: m["auto_models"] || false,
      tags: m["tags"] || [],
      timeout_seconds: m["timeout_seconds"],
      default_context_limit: m["default_context_limit"],
      default_thinking_effort: parse_effort(m["default_thinking_effort"]),
      probe_base_url: m["probe_base_url"],
      auto_probe: if(is_boolean(m["auto_probe"]), do: m["auto_probe"], else: true),
      models: Enum.map(m["models"] || [], &model_from_map/1)
    }
  end

  defp model_from_map(m) do
    %Model{
      name: m["name"],
      context_limit: m["context_limit"],
      multi_modal: m["multi_modal"],
      thinking_effort: parse_effort(m["thinking_effort"])
    }
  end

  defp parse_effort(nil), do: nil
  defp parse_effort(""), do: nil

  defp parse_effort(value) do
    DotConfig.parse_thinking_effort(value)
  end

  defp effort_to_string(nil), do: nil
  defp effort_to_string(effort), do: Atom.to_string(effort)
end
