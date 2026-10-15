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
  alias Nest.DotConfig.ModelValidation
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
        Models.rescan()
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
      "expose_models" => p.expose_models,
      "probe_multimodal" => p.probe_multimodal,
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
    name = m["name"]

    %Provider{
      name: name,
      base_url: m["base_url"],
      api_key: api_key(m["api_key"], name),
      protocol: m["protocol"] || "openai",
      auto_models: m["auto_models"] || false,
      models: Enum.map(m["models"] || [], &model_from_map(&1, name))
    }
    |> Map.merge(validated_fields(m, name))
  end

  # The provider fields the reader can raise on, validated against the same
  # rules the reader uses. Kept apart from the map literal above so the literal
  # stays a list of fields and this stays the set of rules — and so
  # `provider_from_map/1` stays under credo's ABC cap.
  #
  # Every one of these runs **before** `Writer.save_providers/1`, so a refusal
  # writes nothing and the function-level `rescue` in `save/2` answers
  # `invalid_payload`. The GUI inputs they defend against, each measured:
  #
  #   * `default_context_limit` — a bare `type="number"` with no `min` and no
  #     `step`, so `0` and `0.5` are both typable and `Number()` keeps them.
  #   * `timeout_seconds` — no GUI field today; kept here so the two sides stay
  #     defined in one place rather than drifting apart when one is added.
  #   * `tags` — preserved by the GUI, so a malformed list can arrive from a
  #     client that built one itself.
  #   * `api_key` — not a value rule: a reference-shaped key (`${ENV}` / `file:`)
  #     is resolved at load by `KeyValidation`, and the password field can hold
  #     one whose target does not exist.
  #
  # The rules live in `Nest.DotConfig.ModelValidation`, shared with the reader,
  # because the defect they prevent is the two sides disagreeing — which is how
  # a config the app writes for itself becomes one it refuses to read, and that
  # read is on `Models.init/1`'s boot path.
  defp validated_fields(m, name) do
    %{
      tags: tags(m["tags"], name),
      timeout_seconds: timeout_seconds(m["timeout_seconds"], name),
      default_context_limit: default_context_limit(m["default_context_limit"], name),
      default_thinking_effort: parse_effort(m["default_thinking_effort"]),
      probe_base_url: m["probe_base_url"],
      auto_probe: if(is_boolean(m["auto_probe"]), do: m["auto_probe"], else: true),
      expose_models: if(is_boolean(m["expose_models"]), do: m["expose_models"], else: false),
      probe_multimodal: parse_probe_multimodal(m["probe_multimodal"])
    }
  end

  # The opt-in is a boolean, and it is persisted: a non-boolean in the payload
  # is a typo, not a request to opt out, so it raises rather than being
  # silently coerced to `false` (which would write the wrong value to
  # `local.toml`). The function-level `rescue` in `save/2` turns the raise into
  # `invalid_payload`, exactly as a bad thinking-effort value does. Absent
  # (`nil`) keeps the documented default of `false`, matching the TOML parser.
  defp parse_probe_multimodal(value) when is_boolean(value), do: value
  defp parse_probe_multimodal(nil), do: false

  defp parse_probe_multimodal(value) do
    raise "invalid probe_multimodal #{inspect(value)}: must be a boolean"
  end

  defp model_from_map(m, provider_name) do
    name = model_name(m, provider_name)

    %Model{
      name: name,
      context_limit: m["context_limit"],
      multi_modal: multi_modal(m["multi_modal"], provider_name, name),
      thinking_effort: parse_effort(m["thinking_effort"])
    }
  end

  # A model's name must be usable, and it is refused **here** rather than left
  # to the reader.
  #
  # `DotConfig.load/0` rejects a blank or absent name (`ModelValidation`), and
  # that read is on `Nest.Models.init/1`'s boot path with no rescue — so a
  # `local.toml` carrying one turns startup into a crash the supervisor
  # exhausts into an application shutdown. A blank name is the GUI's own
  # default (`emptyModel()` returns `name: ""`), which makes it a config the
  # app writes for itself.
  #
  # Refusing it here is what keeps the writer and the reader a coherent pair:
  # the function-level `rescue` in `save/2` answers `invalid_payload`, so the
  # operator gets a visible error and — because this runs before
  # `Writer.save_providers/1` — **no file is written**. Without this the write
  # succeeded and the raise came later from the re-read, so the operator got an
  # error *and* a bad config on disk.
  #
  # This is one of the guards described under `default_context_limit/2`.
  defp model_name(m, provider_name) do
    ModelValidation.validate_name(m["name"], provider_name)
  end

  # The rules themselves live in `Nest.DotConfig.ModelValidation`, shared with
  # the reader; only the write side's own concern — `nil` means "omit the key",
  # not "use the default" — is decided here. See `validated_fields/2` for the
  # set and why it is validated on this side at all.
  defp default_context_limit(nil, _provider_name), do: nil

  defp default_context_limit(limit, provider_name) do
    ModelValidation.validate_default_context_limit(limit, provider_name)
  end

  defp timeout_seconds(nil, _provider_name), do: nil

  defp timeout_seconds(seconds, provider_name) do
    ModelValidation.validate_timeout(seconds, provider_name)
  end

  defp tags(nil, _provider_name), do: []

  defp tags(tags, provider_name) do
    ModelValidation.validate_tags(tags, provider_name)
  end

  defp multi_modal(nil, _provider_name, _model_name), do: nil

  defp multi_modal(claim, provider_name, model_name) do
    ModelValidation.validate_multi_modal(claim, provider_name, model_name)
  end

  # A reference-shaped api-key is resolved when the config is **read**
  # (`Nest.DotConfig.KeyValidation`, on `load/0` — which is what `Models.init/1`
  # and every rescan call), and an unresolvable one raises there. The api-key
  # field is free text, so an operator can type a `file:` path or a `${ENV}`
  # name whose target does not exist, and the write would succeed before the
  # read refused it.
  #
  # Refusing it here costs nothing that was working: `resolve_api_key/1` is the
  # same resolver the reader uses, a literal key (including the documented
  # `api-key = "none"` opt-out) resolves to itself and passes, and an absent or
  # empty key is not a reference. This is deliberately a *resolution* check
  # rather than a value rule — the target may legitimately not exist yet while
  # the operator is typing, which is why the error names the key so they can
  # correct it.
  defp api_key(nil, _provider_name), do: nil

  defp api_key(key, _provider_name) when is_binary(key) do
    _ = DotConfig.resolve_api_key(key)
    key
  end

  defp api_key(key, _provider_name), do: key

  defp parse_effort(nil), do: nil
  defp parse_effort(""), do: nil

  defp parse_effort(value) do
    DotConfig.parse_thinking_effort(value)
  end

  defp effort_to_string(nil), do: nil
  defp effort_to_string(effort), do: Atom.to_string(effort)
end
