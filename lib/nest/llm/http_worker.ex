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
          (String.t(), term(), term() -> String.t())
        ) :: :ok
  def handle_response(result, parent, client_label, format_chunk) do
    case result do
      {:ok, %Req.Response{status: 200, body: %Req.Response.Async{} = async_body}} ->
        drain_stream(async_body, parent, client_label, format_chunk)

      {:ok, %Req.Response{status: status, body: %Req.Response.Async{} = async_body}} ->
        body = drain_async_error(async_body)
        send(parent, {:req_chunk, format_chunk.("http_error", status, body)})
        send(parent, :req_done)

      {:ok, %Req.Response{status: status, body: body}} ->
        send(parent, {:req_chunk, format_chunk.("http_error", status, body)})
        send(parent, :req_done)

      {:error, reason} ->
        send(parent, {:req_chunk, format_chunk.("request_failed", nil, inspect(reason))})
        send(parent, :req_done)
    end

    :ok
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
  defp drain_stream(async_body, parent, client_label, format_chunk) do
    # `catch kind, reason` (not `rescue`) is intentional: transport
    # failures mid-stream surface as `:exit` (not just exceptions).
    # credo:disable-for-next-line Credo.Check.Readability.PreferImplicitTry
    try do
      Enum.each(async_body, fn chunk ->
        send(parent, {:req_chunk, chunk})
      end)

      send(parent, :req_done)
    catch
      kind, reason ->
        Logger.error("#{client_label} stream_terminated: kind=#{kind} reason=#{inspect(reason)}")

        send(
          parent,
          {:req_chunk, format_chunk.("stream_terminated", nil, "#{kind}: #{inspect(reason)}")}
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
end
