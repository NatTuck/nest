defmodule Nest.LLM.Discover do
  @moduledoc """
  Best-effort discovery of a model's context-window limit and
  multi-modal input support by matching provider-specific
  response shapes from a `/v1/models` request.

  Designed for self-hosted and OpenAI-compatible providers:

  - **vLLM** — top-level `max_model_len` per model
  - **OpenRouter** — top-level `context_length` per model,
    `architecture.input_modalities` for input support
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
    the model takes images, and `nil` when it claims no image
    input — or says nothing about it. Used by `Nest.Models` as
    a *fill-in* only — an explicit static `multi-modal` is
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

  @type source :: :vllm | :openrouter | :llama_cpp | :olla

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

  def extract_limit_from_model(%{} = model) do
    cond do
      is_integer(model["max_model_len"]) ->
        {:vllm, model["max_model_len"]}

      is_integer(model["context_length"]) ->
        {:openrouter, model["context_length"]}

      olla_limit = olla_limit(model) ->
        olla_limit

      meta_limit = meta_limit(model) ->
        meta_limit

      true ->
        nil
    end
  end

  def extract_limit_from_model(_), do: nil

  defp olla_limit(%{"olla" => %{"max_context_length" => limit}}) when is_integer(limit),
    do: {:olla, limit}

  defp olla_limit(_), do: nil

  defp meta_limit(%{"meta" => %{"n_ctx" => limit}}) when is_integer(limit),
    do: {:llama_cpp, limit}

  defp meta_limit(%{"meta" => %{"n_ctx_train" => limit}}) when is_integer(limit),
    do: {:llama_cpp, limit}

  defp meta_limit(_), do: nil

  @doc """
  Return the normalized multi-modal input vocabulary for a single
  model map from a `/models` response, or `nil` when it claims no
  image input — or says nothing about it.

  Three provider shapes are recognized, all normalized to the static
  TOML vocabulary `%{"input" => ["image"]}`:

    * **OpenRouter** — `architecture.input_modalities` (measured:
      `["text", "image", "file"]`)
    * **atlascloud** — top-level `input_modalities`
    * **Anthropic** — `capabilities.image_input.supported`
      (documented only; `true` means image input is accepted)

  `"image"` is the only modality in our vocabulary, so a modality
  list is filtered to it: a list that names modalities but not
  `"image"` (e.g. `["text"]`) is reported as `nil` too, so a consumer
  must read `nil` as "no image input claimed" rather than "unknown".
  A modality list is checked before the Anthropic capability flag —
  an explicit list is the stronger statement — and OpenRouter's
  nested shape before atlascloud's flat one when a body carries both.

  Used by `Nest.Models` (through `Nest.ChatModel`) to *fill in* a
  model's `multi_modal` when static config does not set one; a static
  value is authoritative and is never overwritten by this.
  """
  @spec extract_multi_modal_from_model(map() | nil) :: %{String.t() => [String.t()]} | nil
  def extract_multi_modal_from_model(nil), do: nil

  def extract_multi_modal_from_model(%{} = model) do
    case input_modalities(model) do
      modalities when is_list(modalities) ->
        if "image" in modalities, do: @image_input, else: nil

      _ ->
        if anthropic_image_input?(model), do: @image_input, else: nil
    end
  end

  def extract_multi_modal_from_model(_), do: nil

  defp input_modalities(%{"architecture" => %{"input_modalities" => modalities}})
       when is_list(modalities),
       do: modalities

  defp input_modalities(%{"input_modalities" => modalities}) when is_list(modalities),
    do: modalities

  defp input_modalities(_), do: nil

  # Anthropic's `GET /v1/models` documents a per-model `capabilities`
  # object (`image_input.supported`, alongside batch / citations /
  # pdf_input / …). This branch is unmeasured here — no Anthropic body
  # we control has been captured — so it is kept as the documented
  # shape. It requires exactly `true`, so it cannot misfire on a body
  # that merely lacks the field.
  defp anthropic_image_input?(%{"capabilities" => %{"image_input" => %{"supported" => true}}}),
    do: true

  defp anthropic_image_input?(_), do: false

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
