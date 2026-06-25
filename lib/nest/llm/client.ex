defmodule Nest.LLM.Client do
  @moduledoc """
  Behavior for LLM clients.

  A client speaks one wire protocol (OpenAI-compatible, Anthropic, or
  a test mock) and presents a single canonical event stream to the
  agent. The agent never sees SSE framing, `delta.tool_calls[].index`,
  `content_block_delta` types, or any other provider-specific detail.
  """

  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse

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
          | {:api_key, String.t()}
          | {:base_url, String.t()}
          | {:receive_timeout, non_neg_integer() | :infinity}
          | {:headers, [{String.t(), String.t()}]}
          | {atom(), any()}

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

  # Empty IO list → nil; non-empty → binary. The list is in
  # reverse insertion order (we prepend for O(1) appends), so
  # reverse before flattening. Matches the `RunResponse`
  # struct's `text | nil` and `thinking | nil` shape so a
  # no-content response stays nil.
  defp nil_if_empty([]), do: nil

  defp nil_if_empty(iolist) do
    iolist |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp decode_arguments([]), do: %{}

  defp decode_arguments(buffer) do
    buffer |> Enum.reverse() |> IO.iodata_to_binary() |> Jason.decode() |> handle_decode_result()
  end

  defp handle_decode_result({:ok, decoded}) when is_map(decoded), do: decoded
  defp handle_decode_result(_), do: %{}
end
