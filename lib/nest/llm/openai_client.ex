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

  alias Nest.LLM.Client
  alias Nest.LLM.HttpWorker
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.SSE.Parser
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  @impl Nest.LLM.Client
  def run(%RunRequest{} = request, opts) do
    url = normalize_endpoint(opts[:base_url], "/chat/completions")
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
      "messages" => build_wire_messages(request.messages),
      "stream" => true,
      "stream_options" => %{"include_usage" => true}
    }

    payload
    |> Client.maybe_put("temperature", request.temperature)
    |> Client.maybe_put("max_tokens", request.max_tokens)
    |> Client.maybe_put("top_p", request.top_p)
    |> Client.maybe_put("tools", build_wire_tools(request.tools))
    |> Client.maybe_put("tool_choice", normalize_tool_choice(request.tool_choice))
  end

  defp build_payload(request, opts) do
    format_request_payload(request, opts)
  end

  # System messages (the initial at position 0 and any late
  # reminders at later positions) stay in `request.messages`; the
  # `message_to_wire/1` clause for `{:system, _}` maps them to
  # `{"role": "system", ...}` at their position in the array.
  defp build_wire_messages(messages) do
    Enum.flat_map(messages, &message_to_wire/1)
  end

  defp message_to_wire({:system, %System{parts: parts}}) do
    [%{"role" => "system", "content" => Client.text_from_parts(parts)}]
  end

  defp message_to_wire({:user, %User{parts: parts}}) do
    [%{"role" => "user", "content" => Client.text_from_parts(parts)}]
  end

  defp message_to_wire({:assistant, %Assistant{parts: parts}}) do
    base = %{"role" => "assistant", "content" => Client.text_from_parts(parts)}

    case Client.tool_calls_from_parts(parts) do
      [] -> [base]
      calls -> [Map.put(base, "tool_calls", Enum.map(calls, &tool_call_to_wire/1))]
    end
  end

  defp message_to_wire({:tool, %Tool{parts: parts}}) do
    {text_parts, result_parts} =
      Enum.split_with(parts || [], fn
        %Part.Text{} -> true
        _ -> false
      end)

    text_msgs =
      Enum.map(text_parts, fn %Part.Text{text: text} ->
        %{"role" => "user", "content" => text}
      end)

    result_msgs =
      Enum.map(result_parts, fn %Part.ToolResult{tool_call_id: id, content: content} ->
        %{"role" => "tool", "tool_call_id" => id, "content" => content || ""}
      end)

    text_msgs ++ result_msgs
  end

  defp tool_call_to_wire(%Part.ToolUse{id: id, name: name, arguments: args}) do
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

  # Transport-level failures emit an error chunk with `status: nil`
  # and the inspected `Req` reason in `body` (e.g.
  # `%Finch.TransportError{reason: :econnrefused}`). The previous
  # implementation dropped the body here, leaving the
  # `Runner.format_error/1` output stuck at the bare literal
  # `"request_failed"` with no hint of the actual cause. Match the
  # shape alongside the integer-status clause so the canonical
  # error event carries the reason all the way to the UI.
  defp error_event_from_map(%{"error" => error_type, "status" => nil, "body" => body}) do
    [{:error, {error_type, :transport, body}}]
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

  # Walk every present delta field and emit one event per
  # non-empty value. The OpenAI protocol itself only emits one
  # field per frame, but several OpenAI-compatible providers
  # combine them (notably MiniMax-M3 emits `content` and
  # `tool_calls` in the same frame, and DeepSeek R1-style
  # reasoning models can emit `reasoning_content` alongside
  # `content`). The walk covers all 16 combinations of
  # {content, reasoning_content, refusal, tool_calls} (minus
  # the all-empty case), so no field is silently dropped.
  #
  # The order is fixed: text, thinking, refusal, tool_calls.
  # Downstream consumers don't care about the cross-field
  # order (each is its own canonical event), but pinning the
  # order keeps the test assertions stable.
  @delta_field_extractors [
    {"content", :text},
    {"reasoning_content", :thinking},
    {"refusal", :refusal},
    {"tool_calls", :tool_calls}
  ]

  defp delta_events(delta) do
    Enum.flat_map(@delta_field_extractors, fn {key, kind} ->
      case Map.get(delta, key) do
        text when is_binary(text) and text != "" and kind != :tool_calls ->
          [{kind, text}]

        calls when is_list(calls) and kind == :tool_calls ->
          Enum.flat_map(calls, &tool_call_delta_events/1)

        _ ->
          []
      end
    end)
  end

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

  # vLLM emits the seed frame without an `arguments` field on
  # `function` — only `name` (and a top-level `id`/`index`).
  # Without this clause the seed matches no pattern above and the
  # whole tool call is silently dropped (the follow-up deltas
  # carry `id: :by_index` and have nowhere to land in the
  # accumulator's lazy `tool_index_map`).
  defp tool_call_delta_events(%{
         "index" => idx,
         "id" => id,
         "function" => %{"name" => name}
       })
       when is_binary(id) and is_binary(name) do
    [{:tool_call_start, %{id: id, name: name, index: idx}}]
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
    total_input = Map.get(usage, "prompt_tokens", 0)
    output = Map.get(usage, "completion_tokens", 0)
    # OpenAI's `prompt_tokens_details.cached_tokens` is a subset of
    # `prompt_tokens` served from cache. We split it out so the
    # downstream cost estimation can discount it (the way it does
    # for Anthropic's `cache_read_input_tokens`). The remaining
    # `input_tokens` is the new (non-cached) portion, matching the
    # wire-format semantics of the Anthropic client.
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0
    input = max(total_input - cached, 0)
    # `completion_tokens_details.reasoning_tokens` is a subset of
    # `completion_tokens` charged at the same rate as regular
    # output; the cost module treats `output_tokens` as the
    # total billable output (reasoning included).
    reasoning = get_in(usage, ["completion_tokens_details", "reasoning_tokens"]) || 0

    %{
      input_tokens: input,
      output_tokens: output,
      cache_read_input_tokens: cached,
      cache_creation_input_tokens: 0,
      reasoning_tokens: reasoning,
      total_tokens: Map.get(usage, "total_tokens", input + output)
    }
  end

  # Normalizes a base URL by stripping trailing slashes and any
  # suffix that already matches the target endpoint, then appends
  # the correct endpoint path. Prevents doubled segments like
  # `/v1/v1/messages` or `/chat/completions/chat/completions`.
  @doc false
  def normalize_endpoint(base_url, endpoint) do
    base_url
    |> String.trim_trailing("/")
    |> Client.strip_api_version_if_needed(endpoint)
    |> String.trim_trailing(endpoint)
    |> then(&(&1 <> endpoint))
  end
end
