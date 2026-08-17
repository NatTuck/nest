defmodule Nest.EndpointProbe do
  @moduledoc """
  Determines how to talk to a configured LLM provider by running a
  short, bounded probe sequence.

  The provider config only carries a `base-url` (and optional hints).
  `probe/1` figures out the things a user would otherwise have to
  guess by hand:

    * the wire protocol (`:openai`-compatible vs `:anthropic`),
    * the chat base URL (whether `/v1` is part of it),
    * the model-discovery endpoint (`/models` vs `/v1/models`, and
      whether it lives at a different base than chat — the thing
      `probe-base-url` exists for).

  The probe is intentionally lightweight: a handful of requests with a
  short timeout, each classified by HTTP status (`404` = path absent,
  any other status = the route exists). Results are cached by
  `Nest.EndpointCache` so the probe runs at most once per provider and
  is only re-run when a cached endpoint starts returning `404`.

  `naive_structure/1` produces the pre-probe behaviour purely from
  config with no network I/O — callers use it as the fallback so
  behaviour is unchanged when the probe hasn't run (or failed).
  """

  alias Nest.DotConfig

  @probe_timeout 3_000
  @anthropic_version "2023-06-01"

  defmodule EndpointStructure do
    @moduledoc "The resolved chat + discovery endpoints for a provider."
    @type t :: %__MODULE__{}
    defstruct [
      :provider_name,
      :protocol,
      :chat_base_url,
      :discovery_base_url,
      :models_path,
      :probed_at,
      protocol_resolved?: false,
      discovery_resolved?: false
    ]
  end

  @type status :: :ok | :exists | :missing | :transport

  @doc """
  Build a structure purely from the provider config, with no network
  I/O. This is exactly the behaviour the code had before endpoint
  probing existed: chat uses `base_url`, discovery uses
  `probe_base_url || base_url` with `/models` appended.
  """
  @spec naive_structure(DotConfig.Provider.t()) :: EndpointStructure.t()
  def naive_structure(%DotConfig.Provider{} = provider) do
    %EndpointStructure{
      provider_name: provider.name,
      protocol: protocol_atom(provider.protocol),
      chat_base_url: provider.base_url,
      discovery_base_url: provider.probe_base_url || provider.base_url,
      models_path: "/models",
      probed_at: DateTime.utc_now()
    }
  end

  @doc """
  Probe a provider and return the resolved endpoint structure.

  Returns `{:error, :unreachable}` when the provider has no
  configured base URL or neither a chat nor a discovery route
  responds — i.e. the host is unreachable or wrong. Otherwise the
  structure is returned with best-effort fallbacks (e.g. the default
  OpenAI protocol) for any aspect the probe couldn't confirm.
  """
  @spec probe(DotConfig.Provider.t()) ::
          {:ok, EndpointStructure.t()} | {:error, :unreachable}
  def probe(%DotConfig.Provider{base_url: nil}), do: {:error, :unreachable}

  def probe(%DotConfig.Provider{} = provider) do
    {discovery_base, models_path, discovery_resolved, discovery_body} =
      probe_discovery(provider)

    {protocol, chat_base, protocol_resolved} = probe_protocol(provider, discovery_body)

    if protocol_resolved or discovery_resolved do
      structure = %EndpointStructure{
        provider_name: provider.name,
        protocol: protocol,
        chat_base_url: chat_base,
        discovery_base_url: discovery_base,
        models_path: models_path,
        probed_at: DateTime.utc_now(),
        protocol_resolved?: protocol_resolved,
        discovery_resolved?: discovery_resolved
      }

      {:ok, structure}
    else
      {:error, :unreachable}
    end
  end

  # -- protocol detection ------------------------------------------

  # An explicitly configured Anthropic protocol is trusted outright.
  # Otherwise probe OpenAI-compatible chat first, then Anthropic. When
  # neither chat route is reachable (some servers, e.g. Gemini's
  # OpenAI-compat layer, 404 unknown model ids so a bogus probe model
  # reads as "path absent"), fall back to inferring the protocol from
  # the shape of a successful `/models` discovery body. Defaults to
  # OpenAI when nothing can be confirmed.
  defp probe_protocol(%DotConfig.Provider{protocol: "anthropic"} = provider, _body) do
    {:anthropic, strip(provider.base_url), true}
  end

  defp probe_protocol(%DotConfig.Provider{} = provider, discovery_body) do
    case probe_openai_chat(provider) do
      {:ok, base} ->
        {:openai, base, true}

      :none ->
        base = strip(provider.base_url)

        cond do
          probe_anthropic?(provider) ->
            {:anthropic, base, true}

          protocol = protocol_from_discovery(discovery_body) ->
            {protocol, base, true}

          true ->
            {:openai, base, false}
        end
    end
  end

  defp probe_openai_chat(provider) do
    Enum.reduce_while(candidate_bases(provider), :none, fn base, _acc ->
      url = base <> "/chat/completions"

      case chat_status(url, openai_headers(provider), openai_body()) do
        :exists -> {:halt, {:ok, base}}
        _ -> {:cont, :none}
      end
    end)
  end

  defp probe_anthropic?(provider) do
    url = strip(provider.base_url) <> "/v1/messages"
    chat_status(url, anthropic_headers(provider), anthropic_body()) == :exists
  end

  # Infers the wire protocol from an OpenAI- or Anthropic-shaped
  # `/models` response body, or `nil` when the shape is ambiguous.
  defp protocol_from_discovery(%{"data" => entries}) when is_list(entries) do
    cond do
      Enum.any?(entries, &openai_entry?/1) -> :openai
      Enum.any?(entries, &anthropic_entry?/1) -> :anthropic
      true -> nil
    end
  end

  defp protocol_from_discovery(_), do: nil

  defp openai_entry?(entry) when is_map(entry),
    do: Map.has_key?(entry, "object") or Map.has_key?(entry, "owned_by")

  defp openai_entry?(_), do: false

  defp anthropic_entry?(entry) when is_map(entry),
    do: Map.has_key?(entry, "type") and Map.has_key?(entry, "created_at")

  defp anthropic_entry?(_), do: false

  # -- discovery ---------------------------------------------------

  # Returns `{discovery_base, models_path, resolved?, body}`. A `200`
  # on any candidate is definitive; a non-`404` status (e.g. `401`)
  # suggests the route exists behind an auth issue, so we keep it as a
  # weak fallback. Falls back to the naive config-derived URL otherwise.
  defp probe_discovery(provider) do
    case discovery_candidates(provider) |> pick_result() do
      {base, path, {:ok, body}} -> {base, path, true, body}
      {base, path, {:exists, _}} -> {base, path, true, nil}
      nil -> {strip(provider.probe_base_url || provider.base_url), "/models", false, nil}
    end
  end

  defp discovery_candidates(provider) do
    provider
    |> candidate_bases()
    |> prepend_probe_hint(provider)
    |> Enum.map(fn base ->
      {base, "/models", discovery_result(base <> "/models", discovery_headers(provider))}
    end)
  end

  defp pick_result(results) do
    Enum.find(results, &match?({_, _, {:ok, _}}, &1)) ||
      Enum.find(results, &match?({_, _, {:exists, _}}, &1))
  end

  defp prepend_probe_hint(candidates, provider) do
    case provider.probe_base_url do
      url when is_binary(url) and url != "" -> [strip(url) | candidates] |> Enum.uniq()
      _ -> candidates
    end
  end

  # -- candidate bases / status ------------------------------------

  # Candidate chat + discovery bases: the configured base and the same
  # with `/v1` appended (when not already present). Gemini-style bases
  # like `.../v1beta/openai` are left untouched.
  defp candidate_bases(provider) do
    case strip(provider.base_url) do
      nil -> []
      base -> [base, base <> "/v1"] |> Enum.uniq()
    end
  end

  defp strip(nil), do: nil
  defp strip(url), do: String.trim_trailing(url, "/")

  defp protocol_atom(protocol) when protocol in ["openai", "anthropic"],
    do: String.to_existing_atom(protocol)

  defp protocol_atom(_), do: :openai

  defp discovery_headers(provider), do: auth_headers(provider)
  defp openai_headers(provider), do: auth_headers(provider)

  defp anthropic_headers(provider) do
    [{"x-api-key", key(provider)}, {"anthropic-version", @anthropic_version}]
  end

  defp auth_headers(provider) do
    case key(provider) do
      k when is_binary(k) and k != "" -> [{"Authorization", "Bearer #{k}"}]
      _ -> []
    end
  end

  defp key(provider), do: DotConfig.resolve_api_key(provider.api_key)

  defp discovery_result(url, headers) do
    case get(url, headers) do
      {:ok, 200, body} -> {:ok, body}
      {:ok, 404, _} -> {:missing, nil}
      {:ok, _, _} -> {:exists, nil}
      :transport -> {:transport, nil}
    end
  end

  defp chat_status(url, headers, body) do
    case post(url, headers, body) do
      {:ok, 404} -> :missing
      {:ok, _} -> :exists
      :transport -> :transport
    end
  end

  defp get(url, headers) do
    case Req.get(url, opts(headers)) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      {:ok, %{status: status}} -> {:ok, status, nil}
      {:error, _} -> :transport
    end
  end

  defp post(url, headers, body) do
    case Req.post(url, opts(headers) |> Keyword.put(:json, body)) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, _} -> :transport
    end
  end

  defp opts(headers) do
    [
      headers: headers,
      receive_timeout: @probe_timeout,
      http_errors: :return,
      max_retries: 0
    ]
  end

  # The probe bodies use a deliberately bogus model id so a compliant
  # server returns a non-`404` error (route exists) without producing
  # a real completion.
  defp openai_body do
    %{
      "model" => "__nest_probe__",
      "max_tokens" => 1,
      "messages" => [%{"role" => "user", "content" => "ping"}]
    }
  end

  defp anthropic_body do
    %{
      "model" => "__nest_probe__",
      "max_tokens" => 1,
      "messages" => [%{"role" => "user", "content" => "ping"}]
    }
  end
end
