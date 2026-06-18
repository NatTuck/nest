defmodule Nest.LLM.Discover do
  @moduledoc """
  Best-effort discovery of a model's context-window limit by probing the
  provider's `/v1/models` endpoint.

  Designed for self-hosted and OpenAI-compatible providers that do not
  surface the limit in the streaming chat `usage` chunk:

  - **vLLM** — top-level `max_model_len` per model
  - **OpenRouter** — top-level `context_length` per model
  - **llama.cpp** — `meta.n_ctx` (configured) or `meta.n_ctx_train` (model's
    training max) on each model

  On any failure (network error, non-200, malformed body, missing fields,
  multi-model response with no id match and more than one model) the
  function falls back to `{:default, 128_000}` so the UI always has a
  usable denominator. Callers do not need to handle the empty case.

  The probe is intentionally silent on failure: it is not an error to
  not know the limit, and we do not want logs to fill up when an agent
  is spawned against a provider that has not yet been started.
  """

  alias Nest.LLM.ClientConfig

  @default_limit 128_000
  @probe_timeout 3_000

  @type source :: :vllm | :openrouter | :llama_cpp | :default

  @doc """
  Returns `{source, limit}` for the given client config. The probe is
  fired against `client_config.base_url <> "/models"` with the same auth
  header the chat client would use.
  """
  @spec context_limit(ClientConfig.t()) :: {source(), pos_integer()}
  def context_limit(%ClientConfig{} = client_config) do
    case fetch_models(client_config) do
      {:ok, body} ->
        match_model(body, client_config.model)
        |> extract_limit()

      _ ->
        {:default, @default_limit}
    end
  end

  # `nil` client_config or `nil` base_url means we cannot probe. This
  # handles the case where a future client type doesn't expose an HTTP
  # endpoint we can hit for the model list.
  def context_limit(_), do: {:default, @default_limit}

  defp fetch_models(%ClientConfig{base_url: nil}), do: :error

  defp fetch_models(%ClientConfig{base_url: base_url, api_key: api_key}) do
    url = base_url <> "/models"
    headers = build_headers(api_key)

    case Req.get(url, headers: headers, receive_timeout: @probe_timeout) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _ -> :error
    end
  end

  # The OpenAI `/v1/models` shape is `{"object": "list", "data": [...]}`.
  # We tolerate a bare array (`[...]`) or a top-level `models` key for
  # providers with non-standard shapes.
  defp models_from_body(%{"data" => data}) when is_list(data), do: data
  defp models_from_body(%{"models" => models}) when is_list(models), do: models
  defp models_from_body(models) when is_list(models), do: models
  defp models_from_body(_), do: []

  # Pick the right model from the response.
  #
  # 1. Exact match on `id` — what the client config asked for.
  # 2. Exact match on `id` with a leading path stripped — handles
  #    vLLM / llama.cpp responses that return GGUF file paths
  #    (e.g. `/data/models/llama-3.1-8b.Q4_K_M.gguf`).
  # 3. If the response has exactly one model, use it regardless of id.
  # 4. Otherwise, no match.
  defp match_model(body, model_id) do
    models = models_from_body(body)

    exact =
      Enum.find(models, fn model -> get_id(model) == model_id end)

    cond do
      exact != nil ->
        exact

      (stripped = strip_path(model_id)) != nil ->
        stripped_match =
          Enum.find(models, fn model -> get_id(model) == stripped end)

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

  defp get_id(model) when is_map(model) do
    cond do
      is_binary(model["id"]) -> model["id"]
      is_binary(model["name"]) -> model["name"]
      true -> nil
    end
  end

  defp get_id(_), do: nil

  # Try each known provider shape in priority order. Anything we
  # recognize wins; anything we don't yields the default.
  defp extract_limit(%{} = model) do
    cond do
      is_integer(model["max_model_len"]) ->
        {:vllm, model["max_model_len"]}

      is_integer(model["context_length"]) ->
        {:openrouter, model["context_length"]}

      (meta = model["meta"]) && is_map(meta) ->
        cond do
          is_integer(meta["n_ctx"]) -> {:llama_cpp, meta["n_ctx"]}
          is_integer(meta["n_ctx_train"]) -> {:llama_cpp, meta["n_ctx_train"]}
          true -> {:default, @default_limit}
        end

      true ->
        {:default, @default_limit}
    end
  end

  defp extract_limit(_), do: {:default, @default_limit}

  defp build_headers(nil), do: []

  defp build_headers(""), do: []

  defp build_headers(api_key) do
    [{"Authorization", "Bearer #{api_key}"}]
  end
end
