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

  Historical thinking blocks are request-only. They are never removed
  from the recorded history, but they are excluded from a request when
  thinking is disabled for that request or when the block carries no
  signature to echo back.
  """

  @behaviour Nest.LLM.Client

  alias Nest.LLM.AnthropicStream
  alias Nest.LLM.Client
  alias Nest.LLM.GenerationDefaults
  alias Nest.LLM.HttpWorker
  alias Nest.LLM.RunRequest
  alias Nest.LLM.SSE.Parser
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  @anthropic_version "2023-06-01"
  @max_tokens_default 32_000

  # Anthropic's minimum extended-thinking budget. We never request less
  # than this; if capping the budget to half the output allowance would
  # fall below it, we omit thinking entirely.
  @min_thinking_budget 1_024

  @impl Nest.LLM.Client
  def run(%RunRequest{} = request, opts) do
    url = normalize_endpoint(opts[:base_url], "/v1/messages")
    api_key = Keyword.fetch!(opts, :api_key)
    timeout = Client.first_byte_timeout(opts)
    parent = self()

    headers =
      Client.api_key_header(api_key) ++
        [
          {"anthropic-version", @anthropic_version},
          {"content-type", "application/json"}
        ]

    worker = spawn_link(fn -> http_worker(parent, url, headers, request, opts, timeout) end)

    {:ok,
     consume_sse_from_mailbox(
       worker: worker,
       first_byte_timeout: timeout,
       stream_idle_timeout: Client.stream_idle_timeout(opts)
     )}
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
  defp http_worker(parent, url, headers, request, opts, first_byte_timeout) do
    ctx = HttpWorker.context(url, request.model, request.messages, opts)

    result =
      Req.post(
        url,
        [
          headers: headers,
          json: format_request_payload(request, opts),
          receive_timeout: first_byte_timeout,
          into: :self,
          http_errors: :return
        ] ++ HttpWorker.retry_opts(opts)
      )

    HttpWorker.handle_response(result, parent, "AnthropicClient", &format_error_chunk/3, ctx)
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
  #
  # Options: `:worker` (the socket-reading pid to kill on a stall),
  # `:first_byte_timeout` (ms of allowed silence before the first chunk) and
  # `:stream_idle_timeout` (ms of allowed silence between chunks). Both default
  # to `:infinity`, which disables the watchdog.
  @doc false
  @spec consume_sse_from_mailbox(keyword()) :: Enumerable.t()
  def consume_sse_from_mailbox(opts \\ []) do
    Stream.resource(
      fn -> {Parser.new(), false, AnthropicStream.new(opts)} end,
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
      HttpWorker.watchdog_ms(state) -> timeout_result(parser, state)
    end
  end

  defp handle_req_chunk(parser, chunk, state) do
    {frames, parser} = Parser.feed(parser, chunk)
    {events, state} = AnthropicStream.frames_to_events(frames, state)
    error_seen = state.error_seen or Enum.any?(events, &match?({:error, _}, &1))

    {events, {parser, false, %{state | had_chunk: true, error_seen: error_seen}}}
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

    events =
      cond do
        error_here? ->
          events

        AnthropicStream.complete?(final_state) ->
          events ++ [{:done, %{response: AnthropicStream.done_response(final_state)}}]

        true ->
          events ++ [{:error, {:stream_incomplete, :no_terminator}}]
      end

    {events, {parser, true, final_state}}
  end

  defp handle_stop_chat(parser, state, from) do
    send(from, :stopped)
    HttpWorker.kill_worker(state.worker)
    {:halt, {parser, true, state}}
  end

  # The upstream went silent past whichever bound applies: the first-byte
  # bound if no chunk has arrived yet (a prefill that ran too long), the
  # stream idle bound once streaming. Abandon the socket (kill the worker)
  # and surface a concrete error so the agent can finalize.
  defp timeout_result(parser, state) do
    HttpWorker.kill_worker(state.worker)
    event = {:error, HttpWorker.timeout_event(state)}
    {[event], {parser, true, %{state | error_seen: true}}}
  end

  defp flush_and_finish(parser, state) do
    {frames, _} = Parser.flush(parser)
    AnthropicStream.frames_to_events(frames, state)
  end

  @impl Nest.LLM.Client
  def format_request_payload(%RunRequest{} = request, _opts) do
    {initial_system, conversation_messages} = split_initial_system(request.messages)

    max_tokens =
      request.max_tokens || GenerationDefaults.default_max_tokens(request.model) ||
        @max_tokens_default

    request
    |> build_base_payload(conversation_messages, max_tokens)
    |> Client.maybe_put("system", initial_system)
    |> Client.maybe_put("tools", build_wire_tools(request.tools))
    |> Client.maybe_put("tool_choice", normalize_tool_choice(request.tool_choice))
    |> Client.maybe_put("temperature", request.temperature)
    |> Client.maybe_put(
      "top_p",
      request.top_p || GenerationDefaults.default_top_p(request.model)
    )
    |> maybe_put_thinking(request.thinking_effort, max_tokens)
  end

  # Thinking (extended reasoning) is normalized across providers. For
  # Anthropic, an enabled level sets the `thinking` param with a
  # budget heuristic per level; `:off` and `nil` omit it (Anthropic
  # disables thinking by omitting the param). The requested budget is
  # capped at half the output allowance so thinking can never consume
  # the whole reply; when that cap falls below Anthropic's minimum we
  # omit thinking rather than send an invalid budget.
  @thinking_budgets %{low: 4_000, medium: 8_000, high: 16_000, xhigh: 32_000}

  defp maybe_put_thinking(payload, nil, _max_tokens), do: payload
  defp maybe_put_thinking(payload, :off, _max_tokens), do: payload

  defp maybe_put_thinking(payload, level, max_tokens) do
    case thinking_budget(level, max_tokens) do
      nil -> payload
      budget -> Map.put(payload, "thinking", %{"type" => "enabled", "budget_tokens" => budget})
    end
  end

  defp thinking_budget(level, max_tokens) do
    budget = min(Map.fetch!(@thinking_budgets, level), div(max_tokens, 2))
    if budget >= @min_thinking_budget, do: budget, else: nil
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

  defp build_base_payload(request, conversation_messages, max_tokens) do
    thinking? = thinking_enabled?(request.thinking_effort)

    %{
      "model" => request.model,
      "max_tokens" => max_tokens,
      "messages" => Enum.map(conversation_messages, &message_to_wire(&1, thinking?)),
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
  defp message_to_wire({:system, %System{parts: parts}}, _thinking?) do
    %{"role" => "system", "content" => system_text_from_parts(parts)}
  end

  # User: walk the parts list. Each text part becomes a
  # `text` content block; tool results on the user role are
  # not produced by the agent (the tool role carries them),
  # so this path emits a list of text blocks.
  #
  # Adjacent text parts are coalesced into one block first. A user row can hold
  # more than one `Part.Text` — a drained batch is one part per body, and a
  # backgrounded command's notice splits its prose from the command's output
  # (`Nest.Messages.Segment`, issue #139) — and that split exists for the
  # browser, not for the model. Coalescing keeps the request bytes exactly what
  # they were before the split, so a conversation carrying a notice does not
  # lose its prefix cache on the deploy that introduced it.
  defp message_to_wire({:user, %User{parts: parts}}, _thinking?) do
    %{
      "role" => "user",
      "content" =>
        parts
        |> coalesce_text_parts()
        |> Enum.map(&user_part_to_wire/1)
        |> ensure_content_blocks()
    }
  end

  # Assistant: rebuild the Anthropic content block array from
  # the parts list, preserving text, thinking (with signature),
  # and tool_use blocks in the correct order. Historical
  # thinking blocks are request-only: the recorded history is
  # never mutated, but a thinking block is omitted from the wire
  # when thinking is disabled for this request, or when it has
  # no signature (unsigned reasoning — e.g. history that
  # originated from an OpenAI-compatible model — cannot be
  # replayed because Anthropic validates the signature).
  defp message_to_wire({:assistant, %Assistant{parts: parts}}, thinking?) do
    blocks =
      parts
      |> excluded_thinking(thinking?)
      |> Enum.map(&assistant_part_to_wire/1)

    %{"role" => "assistant", "content" => ensure_content_blocks(blocks)}
  end

  # Tool results: Anthropic expects them in a user-role message with
  # `tool_result` content blocks (not a dedicated tool role). Unlike OpenAI,
  # Anthropic's `tool_result` block accepts image content, so a media part
  # folds INTO the result sharing its `tool_call_id` rather than being hoisted
  # into a separate message.
  defp message_to_wire({:tool, %Tool{parts: parts}}, _thinking?) do
    %{"role" => "user", "content" => tool_blocks(parts || [])}
  end

  defp tool_blocks(parts) do
    results = Enum.filter(parts, &match?(%Part.ToolResult{}, &1))
    media = Enum.filter(parts, &Part.media?/1)
    media_by_id = Enum.group_by(media, & &1.tool_call_id)

    blocks =
      Enum.map(results, fn result ->
        tool_part_to_wire(result, Map.get(media_by_id, result.tool_call_id, []))
      end)

    blocks ++ orphan_media_blocks(media, results)
  end

  # A media part with no result to fold into is unreachable from the batch path,
  # which always emits the pair. It still has to reach the model: an `image`
  # block is valid in a user-role content array, so it rides along instead of
  # being dropped.
  defp orphan_media_blocks(media, results) do
    result_ids = MapSet.new(results, & &1.tool_call_id)

    media
    |> Enum.reject(&MapSet.member?(result_ids, &1.tool_call_id))
    |> Enum.map(&media_block/1)
  end

  # Thinking is "off" for `nil` and `:off` (matching
  # `maybe_put_thinking/2`, which omits the top-level `thinking`
  # param for both).
  defp thinking_enabled?(effort), do: effort not in [nil, :off]

  defp excluded_thinking(parts, thinking?) do
    Enum.reject(parts || [], &exclude_thinking?(&1, thinking?))
  end

  defp exclude_thinking?(%Part.Thinking{signature: signature}, thinking?) do
    not thinking? or is_nil(signature)
  end

  defp exclude_thinking?(_part, _thinking?), do: false

  # Anthropic requires each message's `content` block array to be
  # non-empty. A message with no parts (e.g. an assistant finalized
  # empty after a stop) would otherwise serialize as `content: []`.
  # Insert a neutral text block so the payload stays valid.
  defp ensure_content_blocks([]), do: [%{"type" => "text", "text" => " "}]
  defp ensure_content_blocks(blocks), do: blocks

  # Consecutive `Part.Text` parts become one, in place; every other part keeps
  # its position, so a media part between two texts still separates them.
  defp coalesce_text_parts(parts) do
    parts
    |> List.wrap()
    |> Enum.chunk_by(&match?(%Part.Text{}, &1))
    |> Enum.flat_map(fn
      [%Part.Text{} | _] = run -> [%Part.Text{text: Enum.map_join(run, "", & &1.text)}]
      others -> others
    end)
  end

  defp user_part_to_wire(%Part.Text{text: text}),
    do: %{"type" => "text", "text" => text}

  # Without this clause a media part would fall to the catch-all below, which
  # renders it through `inspect/1` — sending the entire base64 payload as a
  # text block. A silent, expensive, wrong request is worse than a crash,
  # which is why this is not left to the fallback.
  defp user_part_to_wire(%Part.Media{} = media), do: media_block(media)

  defp user_part_to_wire(other), do: %{"type" => "text", "text" => part_to_text(other)}

  defp assistant_part_to_wire(%Part.Text{text: text}) when text != "" and not is_nil(text),
    do: %{"type" => "text", "text" => text}

  defp assistant_part_to_wire(%Part.Thinking{thinking: text, signature: signature})
       when text != "" and not is_nil(text) do
    %{"type" => "thinking", "thinking" => text, "signature" => signature}
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

  # Media is only ever a sibling of a `tool_result`, which the tool role
  # carries, so this is unreachable. It exists so a future bug cannot crash
  # the encoder, and it emits an explicit marker rather than the payload,
  # because an `image` block is not valid on the assistant role.
  defp assistant_part_to_wire(%Part.Media{} = media) do
    %{"type" => "text", "text" => "[#{media.media_type} attachment omitted from assistant role]"}
  end

  # A result with no media keeps today's string content, so every existing
  # request stays byte-identical.
  defp tool_part_to_wire(
         %Part.ToolResult{tool_call_id: id, content: content, is_error: is_error},
         []
       ) do
    %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => content || "",
      "is_error" => is_error || false
    }
  end

  # With media, the block's content becomes an array: the result's own text
  # first, then the image blocks. The text block is always present (even when
  # the anchor is empty) because `tool_result` content must not be empty.
  defp tool_part_to_wire(
         %Part.ToolResult{tool_call_id: id, content: content, is_error: is_error},
         media
       ) do
    %{
      "type" => "tool_result",
      "tool_use_id" => id,
      "content" => [
        %{"type" => "text", "text" => content || ""} | Enum.map(media, &media_block/1)
      ],
      "is_error" => is_error || false
    }
  end

  defp media_block(%Part.Media{modality: :image, media_type: media_type, data: data})
       when is_binary(media_type) and is_binary(data) do
    %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => media_type, "data" => data}
    }
  end

  # A restored part this build cannot send: an unknown modality, or one with no
  # usable type or payload. It is still shown in the panel, so it cannot simply
  # vanish from the request either — and a `text` block is valid both inside a
  # `tool_result` content array and on the user role, so the request stays
  # well-formed.
  defp media_block(%Part.Media{} = media) do
    %{"type" => "text", "text" => Client.media_omitted_note(media)}
  end

  # Render a non-text part as a string for the user-role's
  # flat-text path. Today nothing in the user role carries
  # non-text parts (the tool role carries tool results), so
  # this is a defensive fallback for malformed data.
  defp part_to_text(%Part.Text{text: text}), do: text
  defp part_to_text(other), do: inspect(other)

  @doc false
  def normalize_endpoint(base_url, endpoint) do
    base_url
    |> String.trim_trailing("/")
    |> Client.strip_api_version_if_needed(endpoint)
    |> String.trim_trailing(endpoint)
    |> then(&(&1 <> endpoint))
  end
end
