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

    worker = spawn_link(fn -> http_worker(parent, url, headers, request, opts, timeout) end)

    {:ok, consume_sse_from_mailbox(worker: worker, timeout: timeout)}
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
  # event carrying the accumulated response state, or with an
  # `{:error, _}` event when the connection was dropped or stalled.
  @doc false
  @spec consume_sse_from_mailbox(keyword()) :: Enumerable.t()
  def consume_sse_from_mailbox(opts \\ []) do
    Stream.resource(
      fn -> {Parser.new(), false, initial_state(opts)} end,
      &next_chunk_or_halt/1,
      fn _ -> :ok end
    )
  end

  defp next_chunk_or_halt({_parser, true, _state}), do: {:halt, nil}

  defp next_chunk_or_halt({parser, false, state}),
    do: receive_chunk_or_done({parser, false, state})

  defp receive_chunk_or_done({parser, false, state}) do
    receive do
      {:req_chunk, chunk} ->
        handle_req_chunk(parser, chunk, state)

      :req_done ->
        handle_req_done(parser, state)

      # The agent may interrupt the chat task mid-stream (user
      # clicked Stop). Halt the stream so `Enum.reduce` exits and
      # the chat task can finalize the partial accumulator.
      {:stop_chat, from} ->
        handle_stop_chat(parser, state, from)
    after
      state.watchdog -> timeout_result(parser, state)
    end
  end

  defp handle_req_chunk(parser, chunk, state) do
    {frames, parser} = Parser.feed(parser, chunk)
    {events, state} = frames_to_canonical_events(frames, state)

    state = %{state | error_seen: state.error_seen or Enum.any?(events, &match?({:error, _}, &1))}
    {events, {parser, false, state}}
  end

  # The body ended. A response is complete only when Anthropic sent a
  # `message_stop` terminator or reported a non-nil `stop_reason`. If it
  # did neither (and no error was already emitted), the connection was
  # dropped mid-response: surface `{:stream_incomplete, :no_terminator}`
  # (the partial accumulator is kept downstream) instead of accepting a
  # truncated reply as complete.
  defp handle_req_done(parser, state) do
    {events, final_state} = flush_and_finish(parser, state)

    error_here? = final_state.error_seen or Enum.any?(events, &match?({:error, _}, &1))
    complete? = final_state.terminator or not is_nil(final_state.stop_reason)

    events =
      cond do
        error_here? -> events
        complete? -> events ++ [{:done, %{response: build_done_response(final_state)}}]
        true -> events ++ [{:error, {:stream_incomplete, :no_terminator}}]
      end

    {events, {parser, true, final_state}}
  end

  defp handle_stop_chat(parser, state, from) do
    send(from, :stopped)
    HttpWorker.kill_worker(state.worker)
    {:halt, {parser, true, state}}
  end

  # The upstream went silent for longer than the provider's
  # `receive_timeout`. Abandon the socket (kill the worker) and
  # surface a concrete error so the agent can finalize.
  defp timeout_result(parser, state) do
    HttpWorker.kill_worker(state.worker)
    event = {:error, {:stream_idle_timeout, state.idle_timeout}}
    {[event], {parser, true, %{state | error_seen: true}}}
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
    |> Client.maybe_put("system", initial_system)
    |> Client.maybe_put("tools", build_wire_tools(request.tools))
    |> Client.maybe_put("tool_choice", normalize_tool_choice(request.tool_choice))
    |> Client.maybe_put("temperature", request.temperature)
    |> Client.maybe_put("top_p", request.top_p)
    |> maybe_put_thinking(request.thinking_effort)
  end

  # Thinking (extended reasoning) is normalized across providers. For
  # Anthropic, an enabled level sets the `thinking` param with a
  # budget heuristic per level; `:off` and `nil` omit it (Anthropic
  # disables thinking by omitting the param). Budget values are a
  # reasonable heuristic — tune per model via config if needed.
  @thinking_budgets %{low: 4_000, medium: 8_000, high: 16_000, xhigh: 32_000}

  defp maybe_put_thinking(payload, nil), do: payload
  defp maybe_put_thinking(payload, :off), do: payload

  defp maybe_put_thinking(payload, level) do
    Map.put(payload, "thinking", %{
      "type" => "enabled",
      "budget_tokens" => Map.fetch!(@thinking_budgets, level)
    })
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
      [{:system, %System{parts: parts}} | rest] ->
        text = system_text_from_parts(parts)
        if text != "", do: {text, rest}, else: {nil, messages}

      other ->
        {nil, other}
    end
  end

  defp system_text_from_parts(parts) do
    Client.text_from_parts(parts)
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
  defp message_to_wire({:system, %System{parts: parts}}) do
    %{"role" => "system", "content" => system_text_from_parts(parts)}
  end

  # User: walk the parts list. Each text part becomes a
  # `text` content block; tool results on the user role are
  # not produced by the agent (the tool role carries them),
  # so this path emits a list of text blocks.
  defp message_to_wire({:user, %User{parts: parts}}) do
    %{
      "role" => "user",
      "content" => ensure_content_blocks(Enum.map(parts || [], &user_part_to_wire/1))
    }
  end

  # Assistant: rebuild the Anthropic content block array from
  # the parts list, preserving text, thinking (with signature),
  # and tool_use blocks in the correct order.
  defp message_to_wire({:assistant, %Assistant{parts: parts}}) do
    %{
      "role" => "assistant",
      "content" => ensure_content_blocks(Enum.map(parts || [], &assistant_part_to_wire/1))
    }
  end

  # Tool results: Anthropic expects them in a user-role message with
  # `tool_result` content blocks (not a dedicated tool role).
  defp message_to_wire({:tool, %Tool{parts: parts}}) do
    %{"role" => "user", "content" => Enum.map(parts || [], &tool_part_to_wire/1)}
  end

  # Anthropic requires each message's `content` block array to be
  # non-empty. A message with no parts (e.g. an assistant finalized
  # empty after a stop) would otherwise serialize as `content: []`.
  # Insert a neutral text block so the payload stays valid.
  defp ensure_content_blocks([]), do: [%{"type" => "text", "text" => " "}]
  defp ensure_content_blocks(blocks), do: blocks

  defp user_part_to_wire(%Part.Text{text: text}),
    do: %{"type" => "text", "text" => text}

  defp user_part_to_wire(other), do: %{"type" => "text", "text" => part_to_text(other)}

  defp assistant_part_to_wire(%Part.Text{text: text}) when text != "" and not is_nil(text),
    do: %{"type" => "text", "text" => text}

  defp assistant_part_to_wire(%Part.Thinking{thinking: text, signature: signature})
       when text != "" and not is_nil(text) do
    block = %{"type" => "thinking", "thinking" => text}
    if signature, do: Map.put(block, "signature", signature), else: block
  end

  defp assistant_part_to_wire(%Part.ToolUse{id: id, name: name, arguments: args}) do
    %{
      "type" => "tool_use",
      "id" => id,
      "name" => name,
      "input" => args || %{}
    }
  end

  defp assistant_part_to_wire(%Part.Refusal{refusal: text}) do
    %{"type" => "text", "text" => text}
  end

  defp tool_part_to_wire(%Part.ToolResult{
         tool_call_id: id,
         content: content,
         is_error: is_error
       }) do
    %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => content || "",
      "is_error" => is_error || false
    }
  end

  # Render a non-text part as a string for the user-role's
  # flat-text path. Today nothing in the user role carries
  # non-text parts (the tool role carries tool results), so
  # this is a defensive fallback for malformed data.
  defp part_to_text(%Part.Text{text: text}), do: text
  defp part_to_text(other), do: inspect(other)

  defp initial_state(opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)

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
      worker: Keyword.get(opts, :worker),
      idle_timeout: timeout,
      watchdog: HttpWorker.watchdog_ms(timeout)
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

  # The canonical end-of-message terminator. Its absence (with no
  # `stop_reason` either) is how `handle_req_done/2` detects a dropped
  # connection.
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

  @doc false
  def normalize_endpoint(base_url, endpoint) do
    base_url
    |> String.trim_trailing("/")
    |> Client.strip_api_version_if_needed(endpoint)
    |> String.trim_trailing(endpoint)
    |> then(&(&1 <> endpoint))
  end
end
