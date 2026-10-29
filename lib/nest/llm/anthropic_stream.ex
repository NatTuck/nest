defmodule Nest.LLM.AnthropicStream do
  @moduledoc """
  The accumulator for one Anthropic SSE stream: the per-request state a
  `Nest.LLM.AnthropicClient` consumer carries across chunks, and the
  translation of Anthropic's frames into `Nest.LLM.Client` canonical events.

  Split out of the client because it is a self-contained transformation —
  `frames_to_events/2` is `(frames, state) -> {events, state}` with no I/O —
  while the client is the transport and the mailbox loop.

  The state also carries the consumer's own bookkeeping: the worker pid to kill
  when a silence bound fires, which bound applies (`had_chunk`), and the two
  bounds themselves. Those are read by `Nest.LLM.HttpWorker.watchdog_ms/1` and
  `Nest.LLM.HttpWorker.timeout_event/1`, so the map is one shape shared by this
  module and the consumer loop.
  """

  alias Nest.LLM.RunResponse

  @typedoc """
  One in-flight Anthropic response.

  `terminator` records Anthropic's `message_stop` frame and `stop_reason` its
  `message_delta.stop_reason`; either is enough to call the response complete
  (`complete?/1`), because some proxies close without the `message_stop` frame.
  `error_seen` suppresses the synthesized `:done` on top of a failure.
  """
  @type t :: %{
          model: String.t() | nil,
          message_id: String.t() | nil,
          stop_reason: String.t() | nil,
          terminator: boolean(),
          error_seen: boolean(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer(),
          cache_creation_input_tokens: non_neg_integer(),
          had_chunk: boolean(),
          worker: pid() | nil,
          first_byte_timeout: timeout(),
          stream_idle_timeout: timeout()
        }

  @doc """
  A fresh accumulator from the consumer's opts.

  `:worker`, `:first_byte_timeout` and `:stream_idle_timeout` are the consumer's
  own bookkeeping rather than response state; both timeouts default to
  `:infinity`, which disables the watchdog.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %{
      model: nil,
      message_id: nil,
      stop_reason: nil,
      terminator: false,
      error_seen: false,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0,
      had_chunk: false,
      worker: Keyword.get(opts, :worker),
      first_byte_timeout: Keyword.get(opts, :first_byte_timeout, :infinity),
      stream_idle_timeout: Keyword.get(opts, :stream_idle_timeout, :infinity)
    }
  end

  @doc """
  Translate decoded frames into canonical events, folding each into `state`.
  """
  @spec frames_to_events([term()], t()) :: {[Nest.LLM.Client.event()], t()}
  def frames_to_events(frames, state) do
    Enum.flat_map_reduce(frames, state, fn frame, state -> frame_to_events(frame, state) end)
  end

  @doc """
  Whether the response ended on a proper terminator: Anthropic's `message_stop`
  frame, or a non-nil `stop_reason`. Its absence is how the consumer detects a
  dropped connection.
  """
  @spec complete?(t()) :: boolean()
  def complete?(state), do: state.terminator or not is_nil(state.stop_reason)

  @doc """
  The response state a completed stream finalizes to.
  """
  @spec done_response(t()) :: RunResponse.t()
  def done_response(state) do
    %RunResponse{
      model: state.model,
      stop_reason: state.stop_reason,
      usage: build_usage(state)
    }
  end

  defp build_usage(state) do
    %{
      input_tokens: state.input_tokens,
      output_tokens: state.output_tokens,
      cache_read_input_tokens: state.cache_read_input_tokens,
      cache_creation_input_tokens: state.cache_creation_input_tokens,
      total_tokens: state.input_tokens + state.output_tokens
    }
  end

  defp frame_to_events({:event, "message_start", data}, state) do
    case Jason.decode(data) do
      {:ok, %{"message" => msg}} when is_map(msg) ->
        state =
          state
          |> put_field(:model, msg["model"])
          |> put_field(:message_id, msg["id"])
          |> put_field(:input_tokens, get_in(msg, ["usage", "input_tokens"]) || 0)
          |> put_field(
            :cache_read_input_tokens,
            get_in(msg, ["usage", "cache_read_input_tokens"]) || 0
          )
          |> put_field(
            :cache_creation_input_tokens,
            get_in(msg, ["usage", "cache_creation_input_tokens"]) || 0
          )

        {[], state}

      _ ->
        {[], state}
    end
  end

  defp frame_to_events({:event, "content_block_start", data}, state) do
    case Jason.decode(data) do
      {:ok, %{"content_block" => %{"type" => "tool_use"} = block, "index" => idx}} ->
        {[
           {:tool_call_start, %{id: block["id"], name: block["name"], index: idx}}
         ], state}

      {:ok, %{"content_block" => %{"type" => "thinking", "signature" => sig}}}
      when is_binary(sig) ->
        {[
           {:thinking_signature, sig}
         ], state}

      _ ->
        {[], state}
    end
  end

  defp frame_to_events({:event, "content_block_delta", data}, state) do
    case Jason.decode(data) do
      {:ok, %{"delta" => %{"type" => "text_delta", "text" => text}}} ->
        {[{:text, text}], state}

      {:ok, %{"delta" => %{"type" => "thinking_delta", "thinking" => text}}} ->
        {[{:thinking, text}], state}

      {:ok, %{"delta" => %{"type" => "signature_delta", "signature" => sig}}} ->
        {[
           {:thinking_signature, sig}
         ], state}

      {:ok, %{"delta" => %{"type" => "input_json_delta", "partial_json" => json}, "index" => idx}} ->
        {[
           {:tool_call_delta, %{id: :by_index, index: idx, arguments_delta: json}}
         ], state}

      _ ->
        {[], state}
    end
  end

  defp frame_to_events({:event, "message_delta", data}, state) do
    decoded = Jason.decode(data)
    usage = usage_from_decoded(decoded)

    {state, events} = apply_stop_reason(state, decoded)
    state = apply_usage_field(state, usage, :output_tokens)
    state = apply_usage_field(state, usage, :cache_read_input_tokens)
    state = apply_usage_field(state, usage, :cache_creation_input_tokens)

    {events, state}
  end

  defp frame_to_events({:event, "message_stop", _data}, state) do
    {[], %{state | terminator: true}}
  end

  defp frame_to_events({:event, "error", data}, state) do
    error =
      case Jason.decode(data) do
        {:ok, %{"error" => error_type, "status" => status, "body" => body}}
        when is_integer(status) ->
          {error_type, status, body}

        # Transport failures (connection reset, Finch timeout, etc.)
        # carry a nil status and the inspected reason in `body`. Tag
        # them `:transport` so `Runner.format_error/1` renders the
        # reason instead of the bare SSE error type.
        {:ok, %{"error" => error_type, "status" => nil, "body" => body}} ->
          {error_type, :transport, body}

        {:ok, %{"error" => error}} ->
          error

        _ ->
          data
      end

    {[{:error, error}], %{state | error_seen: true}}
  end

  defp frame_to_events(_other, state), do: {[], state}

  defp apply_stop_reason(state, {:ok, %{"delta" => %{"stop_reason" => reason}}})
       when not is_nil(reason) do
    {put_field(state, :stop_reason, reason), [{:finish_reason, reason}]}
  end

  defp apply_stop_reason(state, _), do: {state, []}

  defp usage_from_decoded({:ok, %{"usage" => usage}}) when is_map(usage), do: usage
  defp usage_from_decoded(_), do: %{}

  # The final `message_delta.usage` block is the authoritative
  # source for the cache fields — it carries the up-to-date
  # `cache_read_input_tokens` and `cache_creation_input_tokens`
  # totals for the completed request. Override the
  # `message_start` values when present; leave the prior
  # values in place when the API didn't report the field on
  # this delta.
  #
  # `usage` is a JSON map with string keys; the state struct
  # uses atom keys. We look up by string and write the value
  # into the state by atom.
  defp apply_usage_field(state, usage, key) do
    case Map.get(usage, Atom.to_string(key)) do
      n when is_integer(n) -> put_field(state, key, n)
      _ -> state
    end
  end

  defp put_field(state, key, value), do: Map.put(state, key, value)
end
