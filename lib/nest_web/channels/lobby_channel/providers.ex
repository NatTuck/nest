defmodule NestWeb.LobbyChannel.Providers do
  @moduledoc """
  Provider-configuration `handle_in` handlers for the LobbyChannel,
  extracted so the parent module stays under the credo 500-line cap.

  `providers/0` serializes the configured `DotConfig.Provider` structs
  for the GUI (used in the lobby `init` payload and the
  `providers_updated` broadcast). `save/2` persists the provider set
  to `~/.config/nest/local.toml` (never `config.toml`), reloads the
  runtime model cache, and broadcasts the new list. The write also
  records the providers the payload dropped, so a provider deleted in
  the GUI is not re-added from `config.toml` on the next load
  (`Nest.DotConfig.Writer` owns that record).

  Admin-only: callers must authorize `is_admin` before calling
  `save/2`.

  ## The api key is write-only

  A provider map carries `has_api_key` and **not** the key. `init` goes to every
  authenticated user, not only admins, and an admin's tab would hold every key
  for as long as it is open, so the value is not in the payload at all (#202).
  To read a key, open `local.toml` — that is the accepted answer, which is why
  there is no reveal, masked suffix or "show" toggle here. Do not "restore" the
  field: a test pins its absence, and the absence is the point.

  A save therefore carries the key in three explicit states rather than echoing
  it: omitted means keep, a value means replace, and `clear_api_key` means
  remove (`api_key_source/2`). `Nest.DotConfig.Writer` merges the kept value from
  the overlay it is about to replace.
  """

  alias Nest.DotConfig
  alias Nest.DotConfig.FieldValidation
  alias Nest.DotConfig.Model
  alias Nest.DotConfig.ModelValidation
  alias Nest.DotConfig.Provider
  alias Nest.DotConfig.Writer
  alias Nest.Models

  @doc """
  Both halves of the provider payload from **one** config load: the serialized
  providers, and the names `local.toml` records as deleted — the providers the
  merge drops even though `config.toml` still defines them.

  One load, for two reasons. It reads and merges both files, which is the
  expensive part; and a snapshot is what makes the two halves agree, where two
  loads could straddle a save and report a provider as both present and deleted.

  The removal record travels to the GUI because without it a provider can vanish
  from the screen with nothing to explain it: a save from a stale tab records as
  deleted every provider its payload did not carry, including ones the operator
  added to `config.toml` afterwards.
  """
  @spec providers_and_deleted() :: {[map()], [String.t()] | nil}
  def providers_and_deleted do
    case DotConfig.load() do
      {:ok, config} ->
        {config.providers |> Map.values() |> Enum.map(&provider_to_map/1),
         Enum.sort(config.deleted_providers)}

      _ ->
        # Not `[]` for the record: a config that cannot be loaded is not a config
        # with no deletions, and the GUI renders a missing record as an explicit
        # unknown where an empty list reads as an answer.
        {[], nil}
    end
  end

  @doc """
  The configured providers, serialized for the GUI.
  """
  @spec providers() :: [map()]
  def providers, do: elem(providers_and_deleted(), 0)

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

        {providers, deleted} = providers_and_deleted()

        Phoenix.Channel.broadcast(socket, "providers_updated", %{
          providers: providers,
          deleted_providers: deleted
        })

        {:reply, :ok, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => "failed_to_save", "message" => reason}}, socket}
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
      "has_api_key" => has_api_key?(p.api_key),
      "protocol" => p.protocol,
      "auto_models" => p.auto_models,
      "tags" => p.tags || [],
      "first_byte_timeout_seconds" => p.first_byte_timeout_seconds,
      "stream_idle_timeout_seconds" => p.stream_idle_timeout_seconds,
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
    # The name is the provider's key in `local.toml` and how it is addressed
    # everywhere, so a blank or whitespace-only one is not a provider — the
    # shared rule, so the reader refuses the same keys (#105 S3).
    name = FieldValidation.provider_name(m["name"])

    {api_key_source, api_key} = api_key_source(m, name)

    %Provider{
      name: name,
      base_url: m["base_url"],
      api_key: api_key,
      api_key_source: api_key_source,
      models:
        m["models"]
        |> ModelValidation.validate_models(name)
        |> Enum.map(&model_from_map(&1, name))
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
  #   * `first_byte_timeout_seconds` / `stream_idle_timeout_seconds` — two
  #     `type="number"` inputs, so a typed `0` arrives as `0` (the string `"0"`
  #     is truthy, so the `? … : null` guard does not catch it) and `min="1"` is
  #     a courtesy, exactly as for `default_context_limit`. The reader raises on
  #     anything that is not a positive integer, so the write side must too.
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
      first_byte_timeout_seconds:
        timeout_seconds(m["first_byte_timeout_seconds"], name, "first_byte_timeout_seconds"),
      stream_idle_timeout_seconds:
        timeout_seconds(m["stream_idle_timeout_seconds"], name, "stream_idle_timeout_seconds"),
      default_context_limit: default_context_limit(m["default_context_limit"], name),
      default_thinking_effort: parse_effort(m["default_thinking_effort"]),
      probe_base_url: probe_base_url(m["probe_base_url"], name),
      protocol: FieldValidation.protocol(m["protocol"], name),
      # One rule for all four flags, on both sides (#105 S1). `auto_models` used
      # to be `m["auto_models"] || false`, which wrote `"no"` through and read
      # back as truthy — a typo that silently turned discovery **on**. The three
      # siblings used to coerce a non-boolean to their default here while the
      # reader raised on it; they are refused now, like `probe_multimodal`
      # already was.
      auto_models: FieldValidation.boolean(m["auto_models"], name, "auto_models", false),
      auto_probe: FieldValidation.boolean(m["auto_probe"], name, "auto_probe", true),
      expose_models: FieldValidation.boolean(m["expose_models"], name, "expose_models", false),
      probe_multimodal:
        FieldValidation.boolean(m["probe_multimodal"], name, "probe_multimodal", false)
    }
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

  # Whether a key is configured — never what it is (#202). A reference
  # (`${ENV}` / `file:`) counts: the provider *has* a key, even though
  # `KeyValidation` resolves it at load and the secret lives elsewhere. Blank does
  # not: an empty string is what a clear writes (so the overlay shadows a key
  # `config.toml` defines), and a whitespace-only key authenticates nothing, so
  # "configured" would promise a usable key that is not there.
  #
  # The one way this can still say true for a provider that cannot authenticate:
  # a reference that resolves to an empty string (a variable that is set but
  # blank). Nothing here can know that without resolving it, and resolving it to
  # decide a placeholder is not worth doing on a payload path.
  defp has_api_key?(key) when is_binary(key), do: String.trim(key) != ""
  defp has_api_key?(_key), do: false

  # The api key's three states, explicit in the payload. The browser never
  # receives the value, so a save cannot say "unchanged" by echoing it:
  #
  #   * no `api_key` and no `clear_api_key` — keep what is on disk;
  #   * `"api_key" => "…"` — validate it (below) and replace;
  #   * `"clear_api_key" => true` — remove it, by writing an empty key that
  #     shadows whatever `config.toml` defines.
  #
  # Nothing is inferred. "Absent means empty" would wipe every key on every save,
  # and "empty means keep" would leave no way to remove one — so an explicit
  # `api_key: ""` is refused rather than guessed at, and so is a payload that
  # both sets and clears.
  defp api_key_source(m, provider_name) do
    clear? = FieldValidation.boolean(m["clear_api_key"], provider_name, "clear_api_key", false)

    case {m["api_key"], clear?} do
      {nil, false} ->
        {keep_source(m, provider_name), nil}

      {nil, true} ->
        {:clear, nil}

      # Before the empty-key clause: a payload that sends both is a contradiction
      # first, and telling it to "send `clear_api_key`" would be false.
      {_key, true} ->
        raise "Provider #{provider_name}: `api_key` and `clear_api_key` contradict each other"

      {"", false} ->
        raise "Provider #{provider_name}: `api_key` is empty: omit it to keep the stored " <>
                "key, or send `clear_api_key` to remove it"

      {key, false} ->
        {:set, api_key(key, provider_name)}
    end
  end

  # Where a keep finds its key: this provider's own name, or — when the payload
  # says the provider was renamed — the name it was stored under (#203). A rename
  # is the same provider with nothing typed, and the browser cannot send the key
  # to carry it, so the writer looks the stored key up by that name.
  #
  # A client-supplied previous name is **not** a key-copy primitive: the handler
  # is admin-only, and an admin can already read and edit `local.toml` on the
  # server, so this crosses no boundary they did not already hold. It cannot
  # name a provider the caller could not otherwise have seen either — the
  # provider list in the payload is the merged one.
  defp keep_source(m, name) do
    case previous_name(m, name) do
      ^name -> :keep
      previous -> {:renamed_from, previous}
    end
  end

  defp previous_name(m, name) do
    case m["previous_name"] do
      blank when blank in [nil, ""] -> name
      previous -> FieldValidation.provider_name(previous)
    end
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

  # Both of the provider's silence bounds, validated by the same rule the reader
  # uses. `nil` (the GUI's blank field) means "omit the key", so the provider
  # keeps `Nest.DotConfig`'s default; anything else must be a positive integer.
  # `field` names the payload key in the error message because there are two of
  # these now, and "invalid timeout" would not say which one the operator has to
  # fix.
  defp timeout_seconds(nil, _provider_name, _field), do: nil

  defp timeout_seconds(seconds, provider_name, field) do
    ModelValidation.validate_timeout(seconds, provider_name, field)
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
  #
  # Only ever called for a key the payload actually carries: "no key" is a state
  # of its own (`api_key_source/2`), not an empty value.
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
