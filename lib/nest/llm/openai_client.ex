defmodule Nest.LLM.OpenAIClient do
  @moduledoc """
  OpenAI-compatible LLM client.

  Speaks the wire format of any provider that exposes a
  `/v1/chat/completions` endpoint with SSE streaming, including
  OpenAI, OpenRouter, DashScope (Qwen), DeepSeek, vLLM, and
  llama.cpp's server. Extends the OpenAI shape with the
  `reasoning_content` delta field emitted by reasoning models
  (Qwen QwQ, DeepSeek R1, llama.cpp with `--reasoning`).
  """

  @behaviour Nest.LLM.Client

  alias Nest.LLM.HttpWorker
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.SSE.Parser
  alias Nest.Messages.Assistant
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User

  @impl Nest.LLM.Client
  def run(%RunRequest{} = request, opts) do
    url = opts[:base_url] <> "/chat/completions"
    api_key = Keyword.fetch!(opts, :api_key)
    timeout = Keyword.get(opts, :receive_timeout, :infinity)
    parent = self()

    spawn_link(fn -> http_worker(parent, url, api_key, request, opts, timeout) end)

    {:ok, build_event_stream()}
  end

  # The HTTP call and the body iteration both run in the worker
  # process. `%Req.Response.Async{}` is process-bound to whoever
  # called `Req.post` — iterating from a child process raises
  # `expected to read body chunk in the process which made the
  # request`. The worker is its own `Req.post` caller, so it can
  # drain the body. All non-200 / error paths are surfaced as
  # synthetic SSE chunks so the consumer always sees a single,
  # uniform event stream. The dispatch logic lives in
  # `Nest.LLM.HttpWorker.handle_response/4`; this function only
  # owns the OpenAI-specific Req options.
  defp http_worker(parent, url, api_key, request, opts, timeout) do
    result =
      Req.post(url,
        auth: {:bearer, api_key},
        json: build_payload(request, opts),
        receive_timeout: timeout,
        into: :self,
        http_errors: :return,
        max_retries: 0
      )

    HttpWorker.handle_response(result, parent, "OpenAIClient", &format_error_chunk/3)
  end

  defp format_error_chunk(kind, status, body) do
    "data: " <> Jason.encode!(%{error: kind, status: status, body: body}) <> "\n\n"
  end

  @impl Nest.LLM.Client
  def format_request_payload(%RunRequest{} = request, _opts) do
    payload = %{
      "model" => request.model,
      "messages" => build_wire_messages(request.messages, request.system_prompt),
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }

    payload
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("max_tokens", request.max_tokens)
    |> maybe_put("top_p", request.top_p)
    |> maybe_put("tools", build_wire_tools(request.tools))
    |> maybe_put("tool_choice", normalize_tool_choice(request.tool_choice))
  end

  defp build_payload(request, opts) do
    format_request_payload(request, opts)
  end

  defp build_wire_messages(messages, system_prompt) do
    messages
    |> prepend_system_message(system_prompt)
    |> Enum.flat_map(&message_to_wire/1)
  end

  defp prepend_system_message(messages, nil), do: messages

  defp prepend_system_message(messages, prompt) do
    [{:system, %System{index: -1, content: prompt}} | messages]
  end

  defp message_to_wire({:system, %System{content: content}}) do
    [%{"role" => "system", "content" => content || ""}]
  end

  defp message_to_wire({:user, %User{content: content}}) do
    [%{"role" => "user", "content" => content}]
  end

  defp message_to_wire({:assistant, %Assistant{content: content, tool_calls: tool_calls}}) do
    base = %{"role" => "assistant", "content" => content || ""}

    case tool_calls do
      nil -> [base]
      [] -> [base]
      calls -> [Map.put(base, "tool_calls", Enum.map(calls, &tool_call_to_wire/1))]
    end
  end

  defp message_to_wire({:tool, %Tool{tool_results: results}}) do
    Enum.map(results, fn %ToolResult{tool_call_id: id, content: content} ->
      %{"role" => "tool", "tool_call_id" => id, "content" => content || ""}
    end)
  end

  defp tool_call_to_wire(%ToolCall{id: id, name: name, arguments: args}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => encode_arguments(args)
      }
    }
  end

  defp encode_arguments(nil), do: "{}"
  defp encode_arguments(args) when is_map(args), do: Jason.encode!(args)
  defp encode_arguments(args) when is_binary(args), do: args

  defp build_wire_tools(nil), do: nil
  defp build_wire_tools([]), do: nil

  defp build_wire_tools(tools) do
    Enum.map(tools, fn t ->
      %{
        "type" => "function",
        "function" => %{
          "name" => t.name,
          "description" => t.description,
          "parameters" => t.parameters_schema || %{"type" => "object", "properties" => %{}}
        }
      }
    end)
  end

  defp normalize_tool_choice(nil), do: nil
  defp normalize_tool_choice(:auto), do: "auto"
  defp normalize_tool_choice(:none), do: "none"
  defp normalize_tool_choice(:required), do: "required"

  defp normalize_tool_choice({:tool, name}) do
    %{"type" => "function", "function" => %{"name" => name}}
  end

  # The stream is a receive loop on the parent's mailbox. The
  # `http_worker` is responsible for calling `Req.post` and
  # draining the `%Req.Response.Async{}` body (it must do both
  # in the same process — see comment on `http_worker/6`). It
  # forwards each chunk as `{:req_chunk, _}` (and `:req_done`
  # at the end) to the parent. The reducer below runs in the
  # consumer's process and pulls from that mailbox, so the
  # consumer can stop early (e.g. via `Stream.take/2` or the
  # agent's iteration loop) by simply halting this resource.
  @spec consume_sse_from_mailbox() :: Enumerable.t()
  def consume_sse_from_mailbox do
    build_event_stream()
  end

  # The third element of the state tuple tracks whether a
  # `{:done, _}` event has been emitted by any chunk
  # processed so far. We need to track this across calls
  # because the `[DONE]` frame can arrive in a chunk that
  # `handle_req_chunk_openai/2` already processed — the final
  # `handle_req_done_openai/1` call only sees whatever was
  # pending in the SSE parser's buffer, which is empty when
  # the `[DONE]` frame was already consumed.
  defp build_event_stream do
    Stream.resource(
      fn -> {Parser.new(), false, false} end,
      fn
        {_parser, true, _had_done} ->
          {:halt, nil}

        {parser, false, had_done} ->
          receive_chunk_or_done_openai(parser, had_done)
      end,
      fn _ -> :ok end
    )
  end

  defp receive_chunk_or_done_openai(parser, had_done) do
    receive do
      {:req_chunk, chunk} -> handle_req_chunk_openai(parser, chunk, had_done)
      :req_done -> handle_req_done_openai(parser, had_done)
      # The agent may interrupt the chat task mid-stream (user
      # clicked Stop). Halt the stream so `Enum.reduce` exits
      # and the chat task can finalize the partial accumulator.
      {:stop_chat, from} -> handle_stop_chat_openai(parser, from)
    after
      60_000 -> {[{:error, :stream_timeout}], {parser, true, had_done}}
    end
  end

  defp handle_req_chunk_openai(parser, chunk, had_done) do
    {frames, parser} = Parser.feed(parser, chunk)
    events = Enum.flat_map(frames, &frame_to_canonical_event/1)
    chunk_had_done = Enum.any?(events, &match?({:done, _}, &1))
    {events, {parser, false, had_done or chunk_had_done}}
  end

  defp handle_req_done_openai(parser, had_done) do
    {frames, _} = Parser.flush(parser)
    events = Enum.flat_map(frames, &frame_to_canonical_event/1)

    # If the upstream body ended without a `data: [DONE]\n\n`
    # frame, synthesize one. The OpenAI wire protocol requires
    # the server to send `[DONE]` at end-of-stream, but
    # providers sometimes close the connection without it
    # (notably reasoning-only responses from some OpenAI-
    # compatible endpoints, where the server's response loop
    # finishes without emitting a final frame). Without this
    # synthesis, the `StreamConsumer` returns `response: nil`,
    # which the dispatcher in `LLMRunner` interprets as a
    # user-initiated stop and routes through `StopHandler` —
    # tagging the partial with `metadata: %{"stopped_by_user"
    # => true}` and skipping the response log. Synthesizing
    # the `:done` event here routes the stream through the
    # normal `handle_new_response/3` path, which calls
    # `Broadcasts.api_response/4` (so the response log lands)
    # and finalizes the partial with the correct metadata.
    #
    # We must check `had_done` (set by a previous chunk) AND
    # the events from this final flush — a `[DONE]` frame
    # could have been delivered in the last chunk and already
    # emitted its `{:done, _}` event in `handle_req_chunk_openai/2`.
    #
    # The carried `%RunResponse{}` is empty so that
    # `normalize_response/2`'s second clause
    # (`%RunResponse{} = response, acc`) merges in text,
    # thinking, tool_calls, thinking_signature, and usage
    # from the accumulator. `stop_reason` is whatever was
    # captured by any `{:finish_reason, _}` event that
    # arrived before the connection closed.
    events =
      if had_done or Enum.any?(events, &match?({:done, _}, &1)) do
        events
      else
        events ++ [{:done, %{response: %RunResponse{}}}]
      end

    {events, {parser, true, had_done}}
  end

  defp handle_stop_chat_openai(parser, from) do
    send(from, :stopped)
    {:halt, {parser, true, false}}
  end

  defp frame_to_canonical_event({:event, _name, "[DONE]"}) do
    [{:done, %{response: %RunResponse{stop_reason: "stop"}}}]
  end

  defp frame_to_canonical_event({:event, _name, data}) do
    case Jason.decode(data) do
      {:ok, %{"choices" => choices} = chunk} when is_list(choices) ->
        events_from_choices(choices) ++ events_from_metadata(chunk)

      {:ok, error_map} when is_map_key(error_map, "error") ->
        error_event_from_map(error_map)

      {:ok, _other} ->
        []

      {:error, %Jason.DecodeError{} = err} ->
        [{:error, {:invalid_json, err, data}}]
    end
  end

  defp frame_to_canonical_event(_other), do: []

  defp error_event_from_map(%{"error" => error_type, "status" => status, "body" => body})
       when is_integer(status) do
    [{:error, {error_type, status, body}}]
  end

  defp error_event_from_map(%{"error" => error}) do
    [{:error, error}]
  end

  defp error_event_from_map(_), do: []

  defp events_from_choices(choices) do
    Enum.flat_map(choices, &events_from_choice/1)
  end

  defp events_from_choice(%{"delta" => delta} = choice) do
    delta_events(delta) ++ finish_event(choice)
  end

  defp events_from_choice(_other), do: []

  defp delta_events(%{"content" => text}) when is_binary(text) and text != "",
    do: [{:text, text}]

  defp delta_events(%{"reasoning_content" => text}) when is_binary(text) and text != "",
    do: [{:thinking, text}]

  defp delta_events(%{"refusal" => text}) when is_binary(text) and text != "",
    do: [{:refusal, text}]

  defp delta_events(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.flat_map(calls, &tool_call_delta_events/1)
  end

  defp delta_events(_), do: []

  # OpenAI's first tool-call delta for a given index carries the
  # `id` and `function.name`; subsequent deltas only carry the
  # `index` and the `function.arguments` fragment. Emit
  # `tool_call_start` only on the seeding delta; emit
  # `tool_call_delta` on every delta (including the seed, with an
  # empty arguments fragment) so the consumer can track partial
  # arguments from the very first delta.
  defp tool_call_delta_events(%{
         "index" => idx,
         "id" => id,
         "function" => %{"name" => name, "arguments" => args}
       })
       when is_binary(id) and is_binary(name) and is_binary(args) do
    [
      {:tool_call_start, %{id: id, name: name, index: idx}},
      {:tool_call_delta, %{id: id, index: idx, arguments_delta: args}}
    ]
  end

  defp tool_call_delta_events(%{"index" => idx, "function" => %{"arguments" => args}})
       when is_binary(args) do
    [{:tool_call_delta, %{id: :by_index, index: idx, arguments_delta: args}}]
  end

  defp tool_call_delta_events(_), do: []

  defp finish_event(%{"finish_reason" => nil}), do: []
  defp finish_event(%{"finish_reason" => reason}), do: [{:finish_reason, reason}]

  # OpenAI-compatible providers (e.g. MiniMax reasoning, DeepSeek
  # R1's interim frames) sometimes send delta frames whose choice
  # has no `finish_reason` key at all. Treat the absence the same
  # as `finish_reason: nil` — the `:finish_reason` event will
  # arrive on the dedicated final frame (the one that carries
  # `stop_reason` in `RunResponse`).
  defp finish_event(_), do: []

  defp events_from_metadata(%{"usage" => usage}) when is_map(usage) do
    [{:usage, parse_usage(usage)}]
  end

  defp events_from_metadata(_), do: []

  defp parse_usage(usage) do
    input = Map.get(usage, "prompt_tokens", 0)
    output = Map.get(usage, "completion_tokens", 0)

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: Map.get(usage, "total_tokens", input + output)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
