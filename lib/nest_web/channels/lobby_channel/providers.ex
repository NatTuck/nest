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
    error ->
      {:reply, {:error, %{"reason" => "invalid_payload", "message" => Exception.message(error)}},
       socket}
  catch
    # A `GenServer.call` to a server that dies inside its callback exits rather
    # than raising, and `rescue` does not catch an exit — so without this the
    # channel process died and the operator got no reply at all. That is what
    # made a bad `probe-base-url` strictly worse than a refused one: the write
    # had already landed, and the only signal was a dead channel.
    # The `reason` stays `failed_to_save` for wire compatibility, but it is not
    # the truth: by the time this fires the write *has* landed, and it is the
    # reload (`Models.rescan/0`) that died. The `message` says so, and the client
    # renders it in preference to the code.
    :exit, _ ->
      {:reply,
       {:error,
        %{
          "reason" => "failed_to_save",
          "message" =>
            "the providers were written to local.toml, but reloading the model cache failed"
        }}, socket}
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
    name = provider_name(m["name"])

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
  #   * `default_context_limit` — a `type="number"` input, and `Number()` keeps a
  #     typed `0` (`e.target.value` is the string `"0"`, which is truthy, so the
  #     `? … : null` guard does not catch it). The input carries `min="1"` and
  #     `step="1"`, but that is a courtesy only: there is no enclosing `<form>`
  #     and nothing calls `checkValidity()`, so the attribute does not stop the
  #     value from being submitted. The refusal here is the guarantee.
  #   * `timeout_seconds` — no GUI field today; kept here so the two sides stay
  #     defined in one place rather than drifting apart when one is added.
  #   * `tags` — preserved by the GUI, so a malformed list can arrive from a
  #     client that built one itself.
  #   * `base_url` — a text field that sends the raw string, so a cleared field
  #     arrives as `""` (the GUI now sends `null` for an empty one, matching
  #     `probe_base_url`). A channel client can send a non-binary, which used to
  #     be persisted and then raise in every chat to that provider.
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
      base_url: base_url(m["base_url"], name),
      tags: tags(m["tags"], name),
      timeout_seconds: timeout_seconds(m["timeout_seconds"], name),
      default_context_limit: default_context_limit(m["default_context_limit"], name),
      default_thinking_effort: parse_effort(m["default_thinking_effort"]),
      probe_base_url: probe_base_url(m["probe_base_url"], name),
      auto_probe: if(is_boolean(m["auto_probe"]), do: m["auto_probe"], else: true),
      expose_models: if(is_boolean(m["expose_models"]), do: m["expose_models"], else: false),
      probe_multimodal: parse_probe_multimodal(m["probe_multimodal"])
    }
  end

  # The provider's name is its key in `local.toml` and how it is addressed
  # everywhere, so an absent or blank one is not a provider. Both used to be
  # accepted, and they collapsed onto the *same* key — `{"name": ""}` and
  # `{"name": null}` both wrote `[providers.""]` — so two different payloads
  # produced one unaddressable provider. The GUI's "add provider" starts a row at
  # `name: ""`, so refusing it means the operator names the provider before
  # saving, exactly as the model-name rule already requires.
  #
  # The reader is left alone: a TOML key is always a string, so there is no
  # non-binary shape to refuse, and an empty one reaches no raising consumer.
  defp provider_name(name) when is_binary(name) and name != "", do: name

  defp provider_name(name) do
    raise "invalid provider name #{inspect(name)}: must be a non-empty string"
  end

  # `base-url` is the last field of this class, and the same shape as
  # `probe-base-url` below: neither side validated it, so the two *agreed* and
  # there was no drift — but the value is dereferenced on every chat, and a
  # non-binary raises `FunctionClauseError` in `String.trim_trailing/2`
  # (`OpenAIClient.normalize_endpoint/2`, `AnthropicClient`, `MultimodalProbe`)
  # and in `EndpointProbe.probe/1`. A channel client sending `7` had it
  # persisted; a browser cannot send `7`, but it does send `""` for a cleared
  # field, and the rule must not rest on one client's coercion.
  defp base_url(nil, _provider_name), do: nil

  defp base_url(url, provider_name) do
    ModelValidation.validate_base_url(url, provider_name)
  end

  # `probe-base-url` is the field that made the class-closure claim false: the
  # reader raises on it (`parse_probe_base_url/2`) and this side passed it
  # through, so a channel client sending `""` (or `7`) had it persisted before
  # any read refused it — and the raise then came from the re-read inside
  # `Models.rescan/0`, which dies without a rescue and takes the next boot with
  # it. A well-behaved browser coerces `""` to `null`, but the rule must not
  # depend on one client's coercion.
  defp probe_base_url(nil, _provider_name), do: nil

  defp probe_base_url(url, provider_name) do
    ModelValidation.validate_probe_base_url(url, provider_name)
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
      context_limit: context_limit(m["context_limit"], provider_name, name),
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
  # Refusing it here is part of keeping the writer and the reader a coherent
  # pair — this is one of the guards in `validated_fields/2`, and the reason they
  # all exist is the same: the reader raises on a value, so the writer must not
  # accept it. The function-level `rescue` in `save/2` answers
  # `invalid_payload`, so the operator gets a visible error and — because this
  # runs before `Writer.save_providers/1` — **no file is written**. Without this
  # the write succeeded and the raise came later from the re-read, so the
  # operator got an error *and* a bad config on disk.
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

  # A model's `context-limit` is refused here for the same reason the provider's
  # `default-context-limit` is: `ProviderModelRow`'s `type="number"` sends
  # `Number("0")` for a typed `0` (the string `"0"` is truthy, so the
  # `e.target.value ? … : null` guard does not catch it), and `0` is not "no
  # limit" — it reaches `Reserve.compaction_reserve/1`'s `limit > 0` guard and
  # raises on **every** agent start. See `ModelValidation.validate_context_limit/3`.
  defp context_limit(nil, _provider_name, _model_name), do: nil

  defp context_limit(limit, provider_name, model_name) do
    ModelValidation.validate_context_limit(limit, provider_name, model_name)
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
  # the operator is typing.
  #
  # The resolver is only *asked*; its result is discarded, so the secret is never
  # written. What is persisted is the reference the operator typed.
  #
  # A non-binary is refused rather than passed through: the reader tolerates one
  # (`KeyValidation` only acts `when is_binary(key)`), so boot is fine, but
  # `resolve_api_key/1` calls `String.starts_with?/2` on it at chat time and
  # raises `FunctionClauseError`.
  defp api_key(nil, _provider_name), do: nil

  defp api_key(key, provider_name) do
    key = ModelValidation.validate_api_key(key, provider_name)
    _ = DotConfig.resolve_api_key(key)
    key
  end

  defp parse_effort(nil), do: nil
  defp parse_effort(""), do: nil

  defp parse_effort(value) do
    DotConfig.parse_thinking_effort(value)
  end

  defp effort_to_string(nil), do: nil
  defp effort_to_string(effort), do: Atom.to_string(effort)
end
