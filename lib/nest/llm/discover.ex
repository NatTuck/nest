defmodule Nest.LLM.Discover do
  @moduledoc """
  Best-effort discovery of a model's context-window limit by
  matching provider-specific response shapes from a
  `/v1/models` request.

  Designed for self-hosted and OpenAI-compatible providers:

  - **vLLM** — top-level `max_model_len` per model
  - **OpenRouter** — top-level `context_length` per model
  - **Olla** — `olla.max_context_length` (Olla wraps upstream
    providers with an OpenAI-shaped `/models` body; the
    context length lives under the `olla` namespace rather
    than at the model root)
  - **llama.cpp** — `meta.n_ctx` (configured) or
    `meta.n_ctx_train` (model's training max)

  The probe is intentionally silent on failure: not knowing
  the limit is not an error, and logging every failed fetch
  would flood logs when an agent is spawned against a
  provider that has not yet been started.

  ## Two entry points

  * `context_limit/1` — for a single model: probes the
    provider, matches the model by id, returns
    `{source, limit}` or a 128k default.
  * `extract_limit_from_model/1` — bulk extraction across
    one row in a `/models` response: returns
    `{source, limit}` when a recognized field is present,
    `nil` otherwise. Used by `Nest.Models` to populate
    its per-model cache.
  """

  alias Nest.LLM.ClientConfig

  @default_limit 128_000
  @probe_timeout 3_000

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
