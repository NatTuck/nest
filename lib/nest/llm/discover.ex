defmodule Nest.LLM.Discover do
  @moduledoc """
  Best-effort discovery of a model's context-window limit and
  multi-modal input support by matching provider-specific
  response shapes from a `/v1/models` request.

  Designed for self-hosted and OpenAI-compatible providers:

  - **vLLM** — top-level `max_model_len` per model
  - **OpenRouter** — top-level `context_length` per model,
    `architecture.input_modalities` for input support
  - **DeepSeek** — top-level `context_window` per model (the
    same body publishes `input_modalities`, which the
    atlascloud shape below already reads: one field mapped
    from that body, the other used to be dropped)
  - **Olla** — `olla.max_context_length` (Olla wraps upstream
    providers with an OpenAI-shaped `/models` body; the
    context length lives under the `olla` namespace rather
    than at the model root)
  - **llama.cpp** — `meta.n_ctx` (configured) or
    `meta.n_ctx_train` (model's training max)
  - **atlascloud** — top-level `input_modalities`
  - **Anthropic** — `capabilities.image_input.supported`

  The probe is intentionally silent on failure: not knowing
  the limit is not an error, and logging every failed fetch
  would flood logs when an agent is spawned against a
  provider that has not yet been started.

  ## Entry points

  * `context_limit/1` — for a single model: probes the
    provider, matches the model by id, returns
    `{source, limit}` or a 128k default.
  * `extract_limit_from_model/1` — bulk extraction across
    one row in a `/models` response: returns
    `{source, limit}` when a recognized field is present,
    `nil` otherwise. Used by `Nest.Models` to populate
    its per-model cache.
  * `extract_multi_modal_from_model/1` — the same bulk pass
    for multi-modal input support: returns the static
    vocabulary `%{"input" => ["image"]}` when the body says
    the model takes images, `%{"input" => []}` when the body
    *declares* no image input, and `nil` when the body says
    nothing we can read. Used by `Nest.Models` as a
    *fill-in* only — an explicit static `multi-modal` is
    never overwritten.

  Every one of these reads a body the caller already fetched:
  nothing here issues an HTTP request of its own.
  """

  alias Nest.LLM.ClientConfig

  @default_limit 128_000
  @probe_timeout 3_000

  # The static TOML vocabulary for multi-modal input support
  # (`multi-modal = { input = ["image"] }` in `config.toml`).
  # Every detected provider shape is normalized to this.
  @image_input %{"input" => ["image"]}
  @text_only %{"input" => []}

  @type source :: :vllm | :openrouter | :context_window | :llama_cpp | :olla

  @doc """
  Probe a provider's `/v1/models` endpoint for the
  context-window limit of the model named in
  `client_config.model`. Returns `{source, limit}` when
  recognized, or `{:default, 128_000}` on failure.
  """
  @spec context_limit(ClientConfig.t()) :: {source() | :default, pos_integer()}
  def context_limit(%ClientConfig{} = client_config) do
    case fetch_models(client_config) do
      {:ok, body} ->
        match_model(body, client_config.model)
        |> extract_limit()
        |> wrap_or_default()

      _ ->
        {:default, @default_limit}
    end
  end

  def context_limit(_), do: {:default, @default_limit}

  defp wrap_or_default({source, _limit} = pair) when source != :default, do: pair
  defp wrap_or_default(_), do: {:default, @default_limit}

  @doc """
  Return the extracted context-limit source + value for a
  single model map from a `/models` response, or `nil` when
  no recognized field is present.

  Used by `Nest.Models` to populate its context-limit cache
  without ever producing the 128k default — a missing entry
  in the cache means "this model isn't known by
  `ProviderShapes`", not "we have a 128k default for it".
  """
  @spec extract_limit_from_model(map() | nil) :: {source(), pos_integer()} | nil
  def extract_limit_from_model(nil), do: nil

  # Field precedence, most specific first: vLLM's `max_model_len`,
  # then OpenRouter's `context_length`, then DeepSeek's
  # `context_window`, then the nested namespaces (Olla, llama.cpp).
  # `context_window` sits *after* `context_length` on purpose: no
  # measured body publishes both, but if one ever does, OpenRouter's
  # field is the narrower claim and keeps priority.
  #
  # `max_input_tokens` is deliberately not read. It is ambiguous
  # (input-only vs. total context), and raven-ferrus — the only
  # provider publishing it — also publishes `context_length`, so it
  # is already covered by the branch above.
  #
  # Every guard requires the value to be **positive**, which is what the `@spec`
  # has always claimed. A published `0` (or a negative) is not a context limit,
  # and passing it through put it straight into `Reserve.compaction_reserve/1`'s
  # `limit > 0` guard clause, which raises on every agent start. A body that
  # publishes one is treated as publishing nothing, so the search falls through
  # to the next field and finally to the default — the safe direction.
  def extract_limit_from_model(%{} = model) do
    cond do
      positive_integer?(model["max_model_len"]) ->
        {:vllm, model["max_model_len"]}

      positive_integer?(model["context_length"]) ->
        {:openrouter, model["context_length"]}

      positive_integer?(model["context_window"]) ->
        {:context_window, model["context_window"]}

      olla_limit = olla_limit(model) ->
        olla_limit

      meta_limit = meta_limit(model) ->
        meta_limit

      true ->
        nil
    end
  end

  def extract_limit_from_model(_), do: nil

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp olla_limit(%{"olla" => %{"max_context_length" => limit}})
       when is_integer(limit) and
              limit > 0,
       do: {:olla, limit}

  defp olla_limit(_), do: nil

  defp meta_limit(%{"meta" => %{"n_ctx" => limit}}) when is_integer(limit) and limit > 0,
    do: {:llama_cpp, limit}

  defp meta_limit(%{"meta" => %{"n_ctx_train" => limit}}) when is_integer(limit) and limit > 0,
    do: {:llama_cpp, limit}

  defp meta_limit(_), do: nil

  @doc """
  Return the normalized multi-modal input vocabulary for a single
  model map from a `/models` response.

  Three answers are possible, and the difference between the last
  two matters to callers — `file-read` refuses a media part
  differently for each:

    * `%{"input" => ["image"]}` — the body says the model takes
      images;
    * `%{"input" => []}` — the body *declares* input modalities and
      does not name `"image"`: a text-only model;
    * `nil` — the body publishes no modality field we recognize, so
      image support is simply unknown.

  Three provider shapes are recognized, all normalized to the static
  TOML vocabulary `%{"input" => ["image"]}`:

    * **OpenRouter** — `architecture.input_modalities` (measured:
      `["text", "image", "file"]`)
    * **atlascloud** — top-level `input_modalities`
    * **Anthropic** — `capabilities.image_input.supported`
      (documented only; `true` means image input is accepted)

  `"image"` is the only modality in our vocabulary, so a modality
  list is filtered to it: a list that names modalities but not
  `"image"` (e.g. `["text"]`) is reported as `%{"input" => []}`.
  Presence is per shape: a field that is missing, or present with a
  value that is not a list, is *unknown* rather than negative. A
  modality list is checked before the Anthropic capability flag —
  an explicit list is the stronger statement — and OpenRouter's
  nested shape before atlascloud's flat one when a body carries both.

  Nested-wins has a consequence worth naming: when a body publishes
  *both* shapes and they disagree, only the nested list is read, so a
  nested list that omits `"image"` answers `%{"input" => []}` -- a
  declared text-only model -- even if the flat list names `"image"`.
  That is a *wrong* negative rather than an unknown. It is accepted
  because no measured provider publishes both shapes at once: they
  come from different providers (OpenRouter nests, atlascloud does
  not), so a body carrying both is not something we expect to meet.
  Were one to appear, the right reading is the union of the two
  lists rather than the nested one alone.

  Used by `Nest.Models` (through `Nest.ChatModel`) to *fill in* a
  model's `multi_modal` when static config does not set one; a static
  value is authoritative and is never overwritten by this.
  """
  @spec extract_multi_modal_from_model(map() | nil) :: %{String.t() => [String.t()]} | nil
  def extract_multi_modal_from_model(nil), do: nil

  def extract_multi_modal_from_model(%{} = model) do
    case modality_list(model) do
      {:published, modalities} -> from_modalities(modalities)
      :absent -> from_anthropic(model)
    end
  end

  def extract_multi_modal_from_model(_), do: nil

  # A published modality list that does not name `"image"` is the
  # provider *declaring* text-only input: an empty `"input"` list, not
  # `nil`. The two are different answers and every consumer has to be
  # able to tell them apart.
  defp from_modalities(modalities) do
    if "image" in modalities, do: @image_input, else: @text_only
  end

  # A modality list is *published* only when the field exists and holds
  # a list. `"input_modalities": "text"` is a shape we do not recognize,
  # so it leaves the answer unknown rather than claiming a negative.
  defp modality_list(%{"architecture" => %{"input_modalities" => modalities}})
       when is_list(modalities),
       do: {:published, modalities}

  defp modality_list(%{"input_modalities" => modalities}) when is_list(modalities),
    do: {:published, modalities}

  defp modality_list(_), do: :absent

  # Anthropic's `GET /v1/models` documents a per-model `capabilities`
  # object (`image_input.supported`, alongside batch / citations /
  # pdf_input / …). This branch is unmeasured here — no Anthropic body
  # we control has been captured — so it is kept as the documented
  # shape. It is only consulted when no modality list was published,
  # and a *boolean* `supported` is read either way: `false` is the
  # provider saying image input is not supported, which is a negative
  # answer, while a missing or non-boolean field says nothing at all.
  defp from_anthropic(%{"capabilities" => %{"image_input" => %{"supported" => supported}}})
       when is_boolean(supported) do
    if supported, do: @image_input, else: @text_only
  end

  defp from_anthropic(_), do: nil

  @doc """
  Extract the model id from a `/models` response entry.
  Handles the two common shapes (`id` for OpenAI / vLLM
  and `name` for Ollama-shaped bodies).
  """
  @spec model_id(map() | nil) :: String.t() | nil
  def model_id(%{} = model) do
    cond do
      is_binary(model["id"]) -> model["id"]
      is_binary(model["name"]) -> model["name"]
      true -> nil
    end
  end

  def model_id(_), do: nil

  # Private helpers — internal to the probe path. Body parsing
  # tolerates OpenAI's `{"data": [...]}` and the alternate
  # `{"models": [...]}` (Ollama) and bare-list bodies.
  defp fetch_models(%ClientConfig{} = config) do
    # The probe URL is the discovery URL — `GET /models`. When
    # `probe_base_url` is set, use it for discovery only; chat
    # callers continue to use `base_url`. Falls back to `base_url`
    # when `probe_base_url` is `nil` (the common case). If both
    # are nil, the call is short-circuited — the provider isn't
    # configured for any HTTP traffic.
    case config.probe_base_url || config.base_url do
      nil ->
        :error

      url ->
        headers = build_headers(config.api_key)

        case Req.get(url <> "/models", headers: headers, receive_timeout: @probe_timeout) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          _ -> :error
        end
    end
  end

  defp models_from_body(%{"data" => data}) when is_list(data), do: data
  defp models_from_body(%{"models" => models}) when is_list(models), do: models
  defp models_from_body(models) when is_list(models), do: models
  defp models_from_body(_), do: []

  defp match_model(body, wanted) do
    models = models_from_body(body)

    exact =
      Enum.find(models, fn model -> public_model_id(model) == wanted end)

    cond do
      exact != nil ->
        exact

      (stripped = strip_path(wanted)) != nil ->
        stripped_match =
          Enum.find(models, fn model -> public_model_id(model) == stripped end)

        if stripped_match, do: stripped_match, else: single_or_nil(models)

      true ->
        single_or_nil(models)
    end
  end

  defp single_or_nil([only]), do: only
  defp single_or_nil(_), do: nil

  defp strip_path(id) when is_binary(id) do
    case Path.basename(id) do
      "" -> nil
      basename when basename == id -> nil
      basename -> basename
    end
  end

  defp strip_path(_), do: nil

  defp public_model_id(model) when is_map(model) do
    cond do
      is_binary(model["id"]) -> model["id"]
      is_binary(model["name"]) -> model["name"]
      true -> nil
    end
  end

  defp public_model_id(_), do: nil

  defp extract_limit(%{} = model) do
    case extract_limit_from_model(model) do
      nil -> {:default, @default_limit}
      {source, limit} -> {source, limit}
    end
  end

  defp extract_limit(_), do: {:default, @default_limit}

  defp build_headers(nil), do: []

  defp build_headers(""), do: []

  defp build_headers(api_key) do
    [{"Authorization", "Bearer #{api_key}"}]
  end
end
