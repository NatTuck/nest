defmodule Nest.LLM.HttpWorker do
  @moduledoc """
  Shared HTTP body-draining helpers for the LLM client
  implementations (`Nest.LLM.OpenAIClient`,
  `Nest.LLM.AnthropicClient`).

  `%Req.Response.Async{}` is process-bound to whoever called
  `Req.post`, so each client's `http_worker` runs the request
  in a child process and forwards chunks to its parent's
  mailbox via the `{:req_chunk, _}` / `:req_done` protocol that
  `consume_sse_from_mailbox/0` consumes.

  This module factors out the per-response dispatch
  (streaming success body, async error body, sync error body,
  transport error) so the two clients share the drain logic
  and only differ in their Req options and the SSE error-chunk
  framing.
  """

  require Logger

  # Retry policy for a streaming LLM request.
  #
  # Req retries only when the *request* fails — connect, send, or
  # receive-headers — and never after the response body has started, because
  # `into: :self` hands the body to us once the step chain returns. So a retry
  # can never duplicate or corrupt streamed text; a mid-stream failure is
  # reported as `stream_terminated` instead (see `drain_stream/5`).
  #
  # `:transient` rather than Req's `:safe_transient` default is required: the
  # default retries only safe/idempotent methods, and a chat completion is a
  # POST. Req's transient set is transport errors (`:closed`, `:econnrefused`,
  # `:timeout`) plus 408/429/5xx. A retried POST can in principle produce a
  # second generation if the first attempt did reach the provider: that is a
  # cost risk, not a correctness one, and it is the price of not losing a whole
  # turn to a stale pooled connection.
  @retry_opts [retry: :transient, max_retries: 2, retry_log_level: :info]

  @doc """
  Req options for the retry policy, with a caller override.

  Callers may pass `retry_opts: [...]` in their own opts to override any part of
  the policy. Tests use it to set `retry_delay: fn _ -> 0 end`, so exercising a
  retry does not have to sleep.
  """
  @spec retry_opts(keyword()) :: keyword()
  def retry_opts(opts) do
    Keyword.merge(@retry_opts, Keyword.get(opts, :retry_opts, []))
  end

  @doc """
  Build the context carried into a failure description.

  Failure messages are what an agent — and the human reading the transcript —
  sees, so they name the endpoint, the model and the request size, count the
  retries that were available, and time the attempt. `started_at` is read here,
  before the request is issued, so the elapsed time reported on failure covers
  the whole attempt, retries included.
  """
  @spec context(String.t() | nil, String.t() | nil, list() | nil, keyword()) :: map()
  def context(url, model, messages, opts) do
    %{
      host: host_of(url),
      model: model,
      messages: length(messages || []),
      retries: Keyword.get(retry_opts(opts), :max_retries),
      started_at: System.monotonic_time(:millisecond)
    }
  end

  defp host_of(nil), do: nil

  defp host_of(url) do
    case URI.parse(url) do
      %URI{host: host} -> host
      _ -> nil
    end
  end

  @doc """
  Handle a `Req.post` result and forward its body to `parent`
  via the `{:req_chunk, _}` / `:req_done` protocol.

  The four cases are:

    * 200 + async body — drain the success stream with a
      try/catch that emits a synthetic error chunk on
      mid-stream transport failures
    * non-200 + async body — drain the error body, then
      emit a single `http_error` chunk
    * non-200 + sync body — emit a single `http_error` chunk
    * `{:error, reason}` — emit a single `request_failed`
      chunk

  `format_chunk` renders an error chunk's wire bytes; the
  clients differ on whether the SSE `event:` line is included.
  `client_label` is used in the catch-path log message.
  """
  @spec handle_response(
          Req.Response.t() | {:error, term()},
          pid(),
          String.t(),
          (String.t(), term(), term() -> String.t()),
          map()
        ) :: :ok
  def handle_response(result, parent, client_label, format_chunk, ctx \\ %{}) do
    case result do
      {:ok, %Req.Response{status: 200, body: %Req.Response.Async{} = async_body}} ->
        drain_stream(async_body, parent, client_label, format_chunk, ctx)

      {:ok, %Req.Response{status: status, body: %Req.Response.Async{} = async_body}} ->
        emit_http_error(parent, format_chunk, status, drain_async_error(async_body), ctx)

      {:ok, %Req.Response{status: status, body: body}} ->
        emit_http_error(parent, format_chunk, status, body, ctx)

      {:error, reason} ->
        emit_transport_error(parent, format_chunk, reason, ctx)
    end

    :ok
  end

  # One error chunk plus the terminator, so each branch above stays a single
  # call (and `handle_response/5` stays inside credo's complexity budget).
  defp emit_http_error(parent, format_chunk, status, body, ctx) do
    send_error(parent, format_chunk, "http_error", status, describe_http_error(status, body, ctx))
  end

  defp emit_transport_error(parent, format_chunk, reason, ctx) do
    send_error(parent, format_chunk, "request_failed", nil, describe_transport(reason, ctx))
  end

  defp send_error(parent, format_chunk, kind, status, rendered) do
    send(parent, {:req_chunk, format_chunk.(kind, status, rendered)})
    send(parent, :req_done)
  end

  # The idle watchdog a client's SSE consumer arms while it waits for the
  # next `{:req_chunk, _}` from this worker. It fires at the provider's
  # socket `receive_timeout` (Finch's per-chunk timeout). Whichever fires
  # first, the consumer surfaces a concrete error and kills the worker;
  # when Finch wins we get its richer `stream_terminated` reason, and when
  # the watchdog wins we report `{:stream_idle_timeout, timeout}`. Keeping
  # the two at the same value (rather than adding a grace) means tests can
  # drive a tiny timeout without waiting seconds. `:infinity` stays
  # `:infinity` so a caller can opt out of the watchdog entirely.
  @spec watchdog_ms(timeout()) :: timeout()
  def watchdog_ms(:infinity), do: :infinity
  def watchdog_ms(timeout) when is_integer(timeout), do: timeout
  def watchdog_ms(_other), do: :infinity

  # Kill a spawned Req worker whose socket read we're abandoning (idle
  # watchdog or cooperative stop). A linked `:normal` exit does not stop a
  # process blocked in `Enum.each/2` over a `%Req.Response.Async{}`, so we
  # must be explicit or the socket lingers until Finch's own timeout.
  # Unlink first: the worker is `spawn_link`ed to the consumer, and a
  # hard `:killed` would otherwise propagate back and take the consumer
  # (the chat-turn worker) down with it.
  @spec kill_worker(pid() | nil) :: :ok
  def kill_worker(pid) when is_pid(pid) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  def kill_worker(_other), do: :ok

  # `%Req.Response.Async{}` is enumerable and yields raw
  # chunk bytes via its `fun.(data, acc)` callback — the
  # `:data` / `:trailers` / `:done` framing is consumed
  # internally by `response_async.ex` and is NOT what the
  # caller's reducer sees. `Enum.each` returns once the
  # underlying stream signals `:done` (or raises if the
  # transport is torn down mid-read), so we send `:req_done`
  # immediately after the iteration completes.
  defp drain_stream(async_body, parent, client_label, format_chunk, ctx) do
    # Bytes already forwarded, so a mid-stream failure can report how far the
    # response got. `:counters` rather than a reducer accumulator because the
    # value has to survive the `catch` that unwinds the iteration.
    bytes = :counters.new(1, [])

    # `catch kind, reason` (not `rescue`) is intentional: transport
    # failures mid-stream surface as `:exit` (not just exceptions).
    # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
    try do
      Enum.each(async_body, fn chunk ->
        :counters.add(bytes, 1, byte_size(chunk))
        send(parent, {:req_chunk, chunk})
      end)

      send(parent, :req_done)
    catch
      kind, reason ->
        Logger.error("#{client_label} stream_terminated: kind=#{kind} reason=#{inspect(reason)}")

        send(
          parent,
          {:req_chunk,
           format_chunk.(
             "stream_terminated",
             nil,
             describe_stream_failure(kind, reason, :counters.get(bytes, 1), ctx)
           )}
        )

        send(parent, :req_done)
    end
  end

  # Non-200 responses also have async bodies when `into: :self`
  # is used. Drain the error body in the worker (allowed since
  # we called `Req.post`), collect it, and send as a single
  # error chunk.
  defp drain_async_error(async_body) do
    async_body
    |> Enum.reduce([], fn chunk, acc -> [acc, chunk] end)
    |> IO.iodata_to_binary()
  end

  # ---- Failure descriptions ------------------------------------------------

  # These become the text an agent — and the human reading the transcript — sees.
  # Before this they were only the inspected `Req` reason, which said *what*
  # failed but not *where*, *how far* it got, or *how many attempts* were spent.

  defp describe_transport(reason, ctx) do
    join_lines([transport_phrase(reason), context_line(ctx), inspect(reason)])
  end

  defp describe_stream_failure(kind, reason, bytes, ctx) do
    join_lines([
      "the response stream ended mid-flight after #{bytes} bytes " <>
        "(#{kind}: #{inspect(reason)})",
      context_line(ctx)
    ])
  end

  defp describe_http_error(status, body, ctx) do
    join_lines(["the provider returned HTTP #{status}", text(body), context_line(ctx)])
  end

  # One plain-English line for the transport reasons Req treats as transient, so
  # the reader does not have to decode a Mint reason atom.
  defp transport_phrase(%Req.TransportError{reason: :closed}),
    do: "the provider closed the connection before responding"

  defp transport_phrase(%Req.TransportError{reason: :econnrefused}),
    do: "could not connect to the provider"

  defp transport_phrase(%Req.TransportError{reason: :timeout}),
    do: "the provider did not respond within the receive timeout"

  defp transport_phrase(%Req.TransportError{reason: reason}),
    do: "the request to the provider failed (#{inspect(reason)})"

  defp transport_phrase(reason), do: "the request to the provider failed: #{inspect(reason)}"

  defp context_line(ctx) when map_size(ctx) == 0, do: nil

  defp context_line(ctx) do
    [
      field("host", ctx[:host]),
      field("model", ctx[:model]),
      field("messages", ctx[:messages]),
      field("retries", ctx[:retries]),
      field("elapsed", elapsed_field(ctx))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp field(_name, nil), do: nil
  defp field(name, value), do: "#{name}=#{value}"

  defp elapsed_field(ctx) do
    case elapsed_ms(ctx) do
      nil -> nil
      ms -> "#{ms}ms"
    end
  end

  defp elapsed_ms(%{started_at: t0}) when is_integer(t0),
    do: System.monotonic_time(:millisecond) - t0

  defp elapsed_ms(_ctx), do: nil

  # A body that is already text stays as-is; anything else (a decoded JSON map,
  # say) is inspected so the SSE chunk always carries a string.
  defp text(body) when is_binary(body), do: body
  defp text(nil), do: nil
  defp text(body), do: inspect(body)

  defp join_lines(lines) do
    lines
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end
end
