defmodule Nest.LLM.AnthropicClient do
  @moduledoc """
  Anthropic Messages API client.

  Speaks the wire format of `https://api.anthropic.com/v1/messages`
  with SSE streaming (named `event:` lines), including:

    * Text content blocks
    * Extended thinking blocks (with `signature` for echo-back on
      multi-turn)
    * Tool use blocks (`tool_use` / `input_json_delta`)

  Captures the Anthropic `thinking_signature` from
  `content_block_start.signature` or `signature_delta` and exposes
  it on the canonical `{:thinking_signature, _}` event so the
  accumulator can preserve it in the assistant turn for replay.
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

  @anthropic_version "2023-06-01"
  @max_tokens_default 4096

  @impl Nest.LLM.Client
  def run(%RunRequest{} = request, opts) do
    url = normalize_endpoint(opts[:base_url], "/v1/messages")
    api_key = Keyword.fetch!(opts, :api_key)
    timeout = Keyword.get(opts, :receive_timeout, :infinity)
    parent = self()

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]

    spawn_link(fn -> http_worker(parent, url, headers, request, opts, timeout) end)

    {:ok, consume_sse_from_mailbox()}
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
  # owns the Anthropic-specific Req options.
  defp http_worker(parent, url, headers, request, opts, timeout) do
    result =
      Req.post(url,
        headers: headers,
        json: format_request_payload(request, opts),
        receive_timeout: timeout,
        into: :self,
        http_errors: :return,
        max_retries: 0
      )

    HttpWorker.handle_response(result, parent, "AnthropicClient", &format_error_chunk/3)
  end

  defp format_error_chunk(kind, status, body) do
    "event: error\ndata: " <>
      Jason.encode!(%{error: kind, status: status, body: body}) <> "\n\n"
  end

  # Public-for-testing: a stream of canonical events consumed from
  # the calling process's mailbox. The mailbox protocol is:
  #
  #   {:req_chunk, binary}  — raw SSE bytes (one or more)
  #   :req_done             — end of stream
  #
  # The stream terminates with a single `{:done, %{response: _}}`
  # event carrying the accumulated response state.
  @doc false
  @spec consume_sse_from_mailbox() :: Enumerable.t()
  def consume_sse_from_mailbox do
    Stream.resource(
      fn -> {Parser.new(), false, initial_state()} end,
      &next_chunk_or_halt/1,
      fn _ -> :ok end
    )
  end

  defp next_chunk_or_halt({_parser, true, _state}), do: {:halt, nil}

  defp next_chunk_or_halt({parser, false, state}),
    do: receive_chunk_or_done({parser, false, state})

  defp receive_chunk_or_done({parser, false, state}) do
    receive do
      {:req_chunk, chunk} -> handle_req_chunk(parser, chunk, state)
      :req_done -> handle_req_done(parser, state)
      # The agent may interrupt the chat task mid-stream (user
      # clicked Stop). Halt the stream so `Enum.reduce` exits and
      # the chat task can finalize the partial accumulator.
      {:stop_chat, from} -> handle_stop_chat(parser, state, from)
    after
      60_000 -> timeout_result(parser, state)
    end
  end

  defp handle_req_chunk(parser, chunk, state) do
    {frames, parser} = Parser.feed(parser, chunk)
    {events, state} = frames_to_canonical_events(frames, state)
    {events, {parser, false, state}}
  end

  defp handle_req_done(parser, state) do
    {events, final_state} = flush_and_finish(parser, state)

    {events ++ [{:done, %{response: build_done_response(final_state)}}],
     {parser, true, final_state}}
  end

  defp handle_stop_chat(parser, state, from) do
    send(from, :stopped)
    {:halt, {parser, true, state}}
  end

  defp timeout_result(parser, state) do
    {[
       {:error, :stream_timeout},
       {:done, %{response: build_done_response(state)}}
     ], {parser, true, state}}
  end

  defp flush_and_finish(parser, state) do
    {frames, _} = Parser.flush(parser)
    frames_to_canonical_events(frames, state)
  end

  @impl Nest.LLM.Client
  def format_request_payload(%RunRequest{} = request, _opts) do
    {initial_system, conversation_messages} = split_initial_system(request.messages)

    request
    |> build_base_payload(conversation_messages)
    |> maybe_put("system", initial_system)
    |> maybe_put("tools", build_wire_tools(request.tools))
    |> maybe_put("tool_choice", normalize_tool_choice(request.tool_choice))
    |> maybe_put("temperature", request.temperature)
    |> maybe_put("top_p", request.top_p)
  end

  # The first `{:system, _}` message in `request.messages` is the
  # agent's immutable initial system prompt and belongs in
  # Anthropic's top-level `"system"` field. Late system
  # reminders (e.g. budget warnings) stay in the messages array
  # and are mapped by the `message_to_wire/1` clause for
  # `{:system, _}` (uses Anthropic's `role: "system"` in the
  # messages array, supported as of May 2026).
  defp split_initial_system(messages) do
    case messages do
      [{:system, %System{content: content}} | rest]
      when is_binary(content) and content != "" ->
        {content, rest}

      other ->
        {nil, other}
    end
  end

  defp build_base_payload(request, conversation_messages) do
    %{
      "model" => request.model,
      "max_tokens" => request.max_tokens || @max_tokens_default,
      "messages" => Enum.map(conversation_messages, &message_to_wire/1),
      "stream" => true
    }
  end

  defp build_wire_tools(nil), do: nil
  defp build_wire_tools([]), do: nil

  defp build_wire_tools(tools) do
    Enum.map(tools, fn t ->
      %{
        "name" => t.name,
        "description" => t.description,
        "input_schema" => t.parameters_schema || %{"type" => "object", "properties" => %{}}
      }
    end)
  end

  defp normalize_tool_choice(nil), do: nil
  defp normalize_tool_choice(:auto), do: %{"type" => "auto"}
  defp normalize_tool_choice(:none), do: %{"type" => "none"}

  # Anthropic has no `:required` tool_choice; fall back to `auto`.
  defp normalize_tool_choice(:required), do: %{"type" => "auto"}
  defp normalize_tool_choice({:tool, name}), do: %{"type" => "tool", "name" => name}

  # Late system reminder (Anthropic's `role: "system"` in the
  # messages array, supported as of May 2026). The initial
  # system message was extracted by `format_request_payload/2`
  # and is in the top-level `"system"` field; this clause only
  # fires for any reminder at a later position.
  defp message_to_wire({:system, %System{content: content}}) do
    %{"role" => "system", "content" => content || ""}
  end

  # User: scalar text or list of pre-shaped content blocks.
  defp message_to_wire({:user, %User{content: content}}) when is_binary(content) do
    %{"role" => "user", "content" => content}
  end

  defp message_to_wire({:user, %User{content: parts}}) when is_list(parts) do
    %{"role" => "user", "content" => Enum.map(parts, &content_block_to_wire/1)}
  end

  # Assistant: rebuild the Anthropic content block array so we
  # preserve text, thinking (with signature), and tool_use blocks
  # in the correct order.
  defp message_to_wire({:assistant, %Assistant{} = msg}) do
    %{"role" => "assistant", "content" => build_assistant_blocks(msg)}
  end

  # Tool results: Anthropic expects them in a user-role message with
  # `tool_result` content blocks (not a dedicated tool role).
  defp message_to_wire({:tool, %Tool{tool_results: results}}) when is_list(results) do
    %{"role" => "user", "content" => Enum.map(results, &tool_result_to_wire/1)}
  end

  defp build_assistant_blocks(%Assistant{} = msg) do
    []
    |> maybe_add_text_block(msg.content)
    |> maybe_add_thinking_block(msg.thinking, msg.thinking_signature)
    |> maybe_add_tool_use_blocks(msg.tool_calls)
  end

  defp maybe_add_text_block(blocks, nil), do: blocks
  defp maybe_add_text_block(blocks, ""), do: blocks

  defp maybe_add_text_block(blocks, content),
    do: blocks ++ [%{"type" => "text", "text" => content}]

  defp maybe_add_thinking_block(blocks, nil, _sig), do: blocks
  defp maybe_add_thinking_block(blocks, "", _sig), do: blocks

  defp maybe_add_thinking_block(blocks, thinking, signature) do
    block = %{"type" => "thinking", "thinking" => thinking}
    block = if signature, do: Map.put(block, "signature", signature), else: block
    blocks ++ [block]
  end

  defp maybe_add_tool_use_blocks(blocks, nil), do: blocks
  defp maybe_add_tool_use_blocks(blocks, []), do: blocks

  defp maybe_add_tool_use_blocks(blocks, calls) do
    blocks ++ Enum.map(calls, &tool_call_to_wire/1)
  end

  defp tool_call_to_wire(%ToolCall{id: id, name: name, arguments: args}) do
    %{
      "type" => "tool_use",
      "id" => id,
      "name" => name,
      "input" => args || %{}
    }
  end

  defp tool_result_to_wire(%ToolResult{tool_call_id: id, content: content, is_error: is_error}) do
    %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => content || "",
      "is_error" => is_error || false
    }
  end

  defp content_block_to_wire(%{type: type, content: content}) do
    %{"type" => to_string(type), "content" => content}
  end

  defp initial_state do
    %{
      model: nil,
      message_id: nil,
      stop_reason: nil,
      input_tokens: 0,
      output_tokens: 0,
      cache_read_input_tokens: 0,
      cache_creation_input_tokens: 0
    }
  end

  defp build_done_response(state) do
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

  defp frames_to_canonical_events(frames, state) do
    Enum.flat_map_reduce(frames, state, fn frame, state -> frame_to_events(frame, state) end)
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

  defp frame_to_events({:event, "error", data}, state) do
    error =
      case Jason.decode(data) do
        {:ok, %{"error" => error_type, "status" => status, "body" => body}}
        when is_integer(status) ->
          {error_type, status, body}

        {:ok, %{"error" => error}} ->
          error

        _ ->
          data
      end

    {[{:error, error}], state}
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  def normalize_endpoint(base_url, endpoint) do
    base_url
    |> String.trim_trailing("/")
    |> strip_api_version_if_needed(endpoint)
    |> String.trim_trailing(endpoint)
    |> then(&(&1 <> endpoint))
  end

  defp strip_api_version_if_needed(url, "/v1" <> _rest), do: String.trim_trailing(url, "/v1")
  defp strip_api_version_if_needed(url, _endpoint), do: url
end
