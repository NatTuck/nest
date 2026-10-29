defmodule Nest.LLM.Client do
  require Logger

  @moduledoc """
  Behavior for LLM clients.

  A client speaks one wire protocol (OpenAI-compatible, Anthropic, or
  a test mock) and presents a single canonical event stream to the
  agent. The agent never sees SSE framing, `delta.tool_calls[].index`,
  `content_block_delta` types, or any other provider-specific detail.

  Also exposes a small set of wire-shaping helpers shared by multiple
  clients (text extraction from a parts list, tool-call extraction,
  and endpoint URL normalization).
  """

  alias Nest.DotConfig
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.Messages.Part

  @typedoc """
  Canonical events yielded by the streaming Enumerable.

  The Enumerable is finite and ends with exactly one `{:done, _}`
  event. In-band errors arrive as `{:error, _}` before `:done`.
  """
  @type event ::
          {:text, String.t()}
          | {:thinking, String.t()}
          | {:thinking_signature, String.t()}
          | {:refusal, String.t()}
          | {:tool_call_start, %{id: String.t(), name: String.t()}}
          | {:tool_call_delta, %{id: String.t(), arguments_delta: String.t()}}
          | {:usage, %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}}
          | {:finish_reason, String.t() | nil}
          | {:error, term()}
          | {:done, %{response: RunResponse.t()}}

  @typedoc "Options forwarded to the client at call time"
  @type opt ::
          {:system_prompt, String.t()}
          | {:api_key, String.t() | nil}
          | {:base_url, String.t()}
          | {:first_byte_timeout, non_neg_integer() | :infinity}
          | {:stream_idle_timeout, non_neg_integer() | :infinity}
          | {:headers, [{String.t(), String.t()}]}
          | {atom(), any()}

  # Applied when a provider's config leaves `first_byte_timeout` unset. It bounds
  # a *silent* connection: with `:infinity` both the socket read and the SSE
  # first-byte watchdog are unbounded, so a connection dropped without a FIN/RST
  # hangs the turn forever — and no retry can fire, because a retry needs a
  # failure to react to. The value is the same one `Nest.DotConfig` uses for a
  # provider that sets nothing: 15 minutes, well past any legitimate prefill we
  # have seen (a ~350k-token cache miss is the slow case) while still finite.
  #
  # The idle default is much tighter: once chunks are arriving, two minutes of
  # silence is a dead connection rather than a slow prefill.
  @doc "The first-byte timeout used when a provider config does not set one."
  @spec default_first_byte_timeout_ms() :: pos_integer()
  def default_first_byte_timeout_ms, do: DotConfig.default_first_byte_timeout_seconds() * 1_000

  @doc "The stream idle timeout used when a provider config does not set one."
  @spec default_stream_idle_timeout_ms() :: pos_integer()
  def default_stream_idle_timeout_ms,
    do: DotConfig.default_stream_idle_timeout_seconds() * 1_000

  @doc """
  Resolve the first-byte timeout from call opts.

  An explicit integer — or `:infinity`, to opt out — wins. A missing or `nil`
  value, which is what an unset `ClientConfig.first_byte_timeout` produces,
  falls back to `default_first_byte_timeout_ms/0`.
  """
  @spec first_byte_timeout(keyword()) :: pos_integer() | :infinity
  def first_byte_timeout(opts) do
    case Keyword.get(opts, :first_byte_timeout) do
      nil -> default_first_byte_timeout_ms()
      value -> value
    end
  end

  @doc """
  Resolve the stream idle timeout from call opts.

  Same rules as `first_byte_timeout/1`: an explicit value wins (including
  `:infinity`), and a missing one falls back to
  `default_stream_idle_timeout_ms/0`.
  """
  @spec stream_idle_timeout(keyword()) :: pos_integer() | :infinity
  def stream_idle_timeout(opts) do
    case Keyword.get(opts, :stream_idle_timeout) do
      nil -> default_stream_idle_timeout_ms()
      value -> value
    end
  end

  @doc """
  Req options carrying a bearer credential, or `[]` when there is none.

  `nil` and `""` both mean "no credential configured": a provider with
  no `api-key`, a literal opt-out, or an `${ENV_VAR}` / `file:`
  reference that could not be resolved. The request then goes out with
  no `authorization` header at all and the provider's own `401` is the
  failure — an ordinary error, never a raise. Req has no clause for
  `{:bearer, nil}` (it raises `FunctionClauseError`), which is why
  absence is expressed by omitting the option.
  """
  @spec bearer_auth_opts(String.t() | nil) :: keyword()
  def bearer_auth_opts(api_key) when is_binary(api_key) and api_key != "",
    do: [auth: {:bearer, api_key}]

  def bearer_auth_opts(_none), do: []

  @doc """
  The Anthropic `x-api-key` header, or `[]` when there is no credential
  to send. See `bearer_auth_opts/1` for why an absent credential is a
  legitimate configuration rather than an error.
  """
  @spec api_key_header(String.t() | nil) :: [{String.t(), String.t()}]
  def api_key_header(api_key) when is_binary(api_key) and api_key != "",
    do: [{"x-api-key", api_key}]

  def api_key_header(_none), do: []

  @doc """
  Run a streaming completion.

  Always returns `{:ok, stream}` where `stream` is an `Enumerable`
  yielding canonical events. All failures — connection refused,
  non-2xx status, mid-stream errors — surface as `{:error, _}`
  events inside the stream itself, followed by `:done`. The
  consumer can therefore treat success and failure uniformly by
  always feeding the stream into `accumulate/2` and checking the
  reducer's error field.
  """
  @callback run(RunRequest.t(), [opt()]) :: {:ok, Enumerable.t(event())}

  @doc """
  Render the request as a wire-format payload map.

  Used by the agent to populate the `api_logs` request entry. The
  shape is provider-specific (OpenAI and Anthropic differ) but the
  top level is always a plain map that round-trips through Jason.
  """
  @callback format_request_payload(RunRequest.t(), [opt()]) :: map()

  @typedoc """
  Accumulator state for the canonical event stream.

  Different clients may seed different fields (e.g. Anthropic tracks
  a thinking `signature`; OpenAI does not), but the common skeleton
  is shared.

  `text` and `thinking` are IO lists (nested lists of binaries) to
  avoid the O(n²) cost of repeated string concatenation. They are
  converted to binaries by `finalize/2`. The `arguments_buffer` on
  each tool call is also an IO list.

  `tool_index_map` is lazy: it is only present on the accumulator
  after the first `tool_call_start` has been seen. Callers that
  want a uniform shape can fall back to `%{}` when reading it.
  """
  @type accumulator :: %{
          text: IO.iodata(),
          thinking: IO.iodata(),
          thinking_signature: String.t() | nil,
          tool_calls: %{
            String.t() =>
              Nest.LLM.Tool.t()
              | %{
                  id: String.t(),
                  name: String.t(),
                  index: non_neg_integer(),
                  arguments_buffer: IO.iodata()
                }
          },
          tool_index_map: %{non_neg_integer() => String.t()} | nil,
          refusal: String.t() | nil,
          usage: RunResponse.usage() | nil,
          stop_reason: String.t() | nil
        }

  @doc """
  Fold a canonical event into an accumulator and return the
  updated accumulator.

  Provided as a default implementation so clients don't have to
  reimplement the accumulation logic unless they need provider-
  specific quirks.

  String fields (`text`, `thinking`, `arguments_buffer`) are built
  as IO lists — O(1) per append. `finalize/2` converts to
  binaries.
  """
  @spec accumulate(accumulator(), event()) :: accumulator()
  def accumulate(acc, {:text, text}) do
    %{acc | text: [text | acc.text]}
  end

  def accumulate(acc, {:thinking, text}) do
    %{acc | thinking: [text | acc.thinking]}
  end

  def accumulate(acc, {:thinking_signature, signature}) do
    %{acc | thinking_signature: signature}
  end

  def accumulate(acc, {:refusal, text}) do
    %{acc | refusal: text}
  end

  def accumulate(acc, {:tool_call_start, %{id: id, name: name} = event}) do
    idx = Map.get(event, :index, 0)
    acc = put_in(acc, [:tool_calls, id], %{id: id, name: name, index: idx, arguments_buffer: []})
    # Lazily seed the index→id map on the first tool call start;
    # text-only / refusal-only runs never need it.
    Map.update(acc, :tool_index_map, %{idx => id}, &Map.put(&1, idx, id))
  end

  def accumulate(acc, {:tool_call_delta, %{id: id, arguments_delta: frag}})
      when is_binary(id) do
    update_in(acc, [:tool_calls, Access.key(id), :arguments_buffer], &[frag | &1])
  end

  def accumulate(acc, {:tool_call_delta, %{id: :by_index, index: idx, arguments_delta: frag}}) do
    case Map.get(Map.get(acc, :tool_index_map, %{}), idx) do
      nil -> acc
      id -> update_in(acc, [:tool_calls, Access.key(id), :arguments_buffer], &[frag | &1])
    end
  end

  def accumulate(acc, {:usage, usage}) do
    %{acc | usage: usage}
  end

  def accumulate(acc, {:finish_reason, reason}) do
    %{acc | stop_reason: reason}
  end

  def accumulate(acc, _other), do: acc

  @doc """
  Build a `RunResponse` from a fully-populated accumulator.
  Converts the IO-list text/thinking/arguments buffers to
  binaries.
  """
  @spec finalize(accumulator(), String.t() | nil) :: RunResponse.t()
  def finalize(acc, model \\ nil) do
    tool_calls =
      acc.tool_calls
      |> Map.values()
      |> Enum.map(fn
        %Nest.LLM.Tool{} = tool ->
          tool

        %{id: id, name: name, arguments_buffer: buffer} ->
          %Nest.Messages.ToolCall{
            id: id,
            name: name,
            arguments: decode_arguments(buffer)
          }
      end)

    %RunResponse{
      text: nil_if_empty(acc.text),
      thinking: nil_if_empty(acc.thinking),
      thinking_signature: acc.thinking_signature,
      tool_calls: tool_calls,
      refusal: acc.refusal,
      usage: acc.usage,
      stop_reason: acc.stop_reason,
      model: model
    }
  end

  # `tool_index_map` is intentionally absent here: it is added
  # lazily by `accumulate/2` on the first `tool_call_start`. A
  # fresh accumulator for a text-only or refusal-only response
  # never needs it.
  @empty_acc %{
    text: [],
    thinking: [],
    thinking_signature: nil,
    tool_calls: %{},
    refusal: nil,
    usage: nil,
    stop_reason: nil
  }

  @doc """
  A fresh accumulator.
  """
  @spec new_accumulator() :: accumulator()
  def new_accumulator, do: @empty_acc

  @doc """
  Put `key` → `value` into `map`, but only when `value` is not `nil`.
  Avoids emitting `"foo": null` JSON fields when serializing maps
  with optional entries.
  """
  @spec maybe_put(map(), atom() | String.t(), any()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Concatenate the text content of every `Part.Text` entry in a
  message's parts list. Returns `""` for `nil` or an empty list.
  Used by the OpenAI and mock clients to flatten the parts model
  into a single string for the wire `content` field.
  """
  @spec text_from_parts([Part.t()] | nil) :: String.t()
  def text_from_parts(nil), do: ""

  def text_from_parts(parts) do
    parts
    |> Enum.filter(&match?(%Part.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  @doc """
  Filter a parts list to the `Part.ToolUse` entries. Returns `[]`
  for `nil` or an empty list. Used by the OpenAI and mock clients
  to surface tool calls alongside the assistant message's text.
  """
  @spec tool_calls_from_parts([Part.t()] | nil) :: [Part.ToolUse.t()]
  def tool_calls_from_parts(nil), do: []

  def tool_calls_from_parts(parts) do
    Enum.filter(parts, &match?(%Part.ToolUse{}, &1))
  end

  @doc """
  The text a provider wire carries in place of a media part this build cannot
  send: one whose modality it does not know (a row restored from a build with a
  wider vocabulary), or one with no usable type or payload.

  Such a part is still rendered in the panel, so it must not simply vanish from
  the request either — the model is told, in text, that something it cannot
  receive is part of the history. A text part is valid on the user role for
  every client here, so the request stays well-formed.
  """
  @spec media_omitted_note(Part.Media.t()) :: String.t()
  def media_omitted_note(%Part.Media{} = media) do
    type = media.media_type || "type not reported"

    "[#{type} attachment omitted from this request: " <>
      "this build cannot send modality #{inspect(media.modality)}]"
  end

  @doc """
  Strip a trailing `/v1` from a base URL only when the endpoint
  already includes it (e.g. `/v1/messages`). For endpoints like
  `/chat/completions`, the `/v1` in the base URL is preserved.
  """
  @spec strip_api_version_if_needed(String.t(), String.t()) :: String.t()
  def strip_api_version_if_needed(url, "/v1" <> _rest), do: String.trim_trailing(url, "/v1")
  def strip_api_version_if_needed(url, _endpoint), do: url

  # Empty IO list → nil; non-empty → binary. The list is in
  # reverse insertion order (we prepend for O(1) appends), so
  # reverse before flattening. Matches the `RunResponse`
  # struct's `text | nil` and `thinking | nil` shape so a
  # no-content response stays nil.
  defp nil_if_empty([]), do: nil

  defp nil_if_empty(iolist) do
    iolist |> Enum.reverse() |> IO.iodata_to_binary()
  end

  # An empty buffer is a call that genuinely carried no arguments: every tool
  # whose arguments are all optional can produce one, so it is not a failure.
  defp decode_arguments([]), do: %{}

  defp decode_arguments(buffer) do
    buffer |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode() |> handle_decode_result()
  end

  defp handle_decode_result({:ok, decoded}) when is_map(decoded), do: decoded

  # A buffer that did not decode is answered with no arguments at all, which
  # downstream is indistinguishable from a call that carried none — and for a
  # tool whose arguments carry content (`context-compact`'s `preserve`) that
  # difference is the whole point of the argument. Worth saying out loud, then.
  # This is the decoder the live path uses (`finalize/2` → `Runner` → the
  # machine's dispatch); `Messages.Streaming`'s decoder is only reached for
  # partials, which the runtime never marks complete.
  defp handle_decode_result({:error, reason}) do
    Logger.warning("tool-call arguments did not decode: #{inspect(reason)}")
    %{}
  end

  defp handle_decode_result({:ok, _}), do: %{}
end
