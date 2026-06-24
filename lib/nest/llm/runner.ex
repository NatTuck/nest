defmodule Nest.LLM.Runner do
  @moduledoc """
  Stateless HTTP client for the LLM call chain. Takes a
  `RunRequest` and a `RunContext`, makes the HTTP call,
  consumes the streaming response, and emits canonical
  events to a callback module.

  The runner is the "I/O half" of the chat turn: it knows
  how to talk to the provider, but it knows nothing about
  iteration, tool execution, message bookkeeping, or budget
  enforcement. The iteration state machine lives in the
  chat turn coordinator (a GenServer in PR 3; for now, a
  Task spawned by `ChatPipeline`).

  ## Streaming callbacks

  The consumer module implements:

    * `c.on_text(text, sent, ctx)` — invoked for each text
      delta. Should broadcast the delta and return the
      updated `sent` map.
    * `c.on_thinking(text, sent, ctx)` — invoked for each
      thinking delta. Same contract as `on_text`.
    * `c.on_signature(signature, ctx)` — invoked for the
      extended-thinking signature (Anthropic only).
    * `c.on_error(error, ctx)` — invoked on a stream-level
      error. The runner has already broadcast the error and
      the chat turn should finalize the partial and stop.
    * `c.on_response(response, ctx)` — invoked once with the
      final `RunResponse` after the stream ends cleanly.
    * `c.should_stop?(ctx)` — non-blocking mailbox check
      returning `true` if the chat turn should halt the
      stream (e.g. the user clicked Stop).

  The ctx is an opaque term the runner passes through to
  every callback; the consumer module is free to use it for
  whatever state it needs (e.g. the agent pid, the message
  index for delta broadcasts, the streaming accumulator).
  """

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.LLM.Client
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer

  require Logger

  @type ctx :: term()
  @type consumer :: module()

  @doc """
  Build a `RunRequest` from a `RunContext`. The
  `RunContext` is the orchestration-side view; the
  `RunRequest` is the provider-facing view. Kept as a
  separate function so the wire format can diverge from the
  orchestration schema without rewiring callers.
  """
  @spec build_request(map()) :: RunRequest.t()
  def build_request(ctx) do
    %RunRequest{
      # System messages (initial at position 0, late reminders at
      # later positions) stay in the messages array. Each client
      # shapes them for its wire protocol.
      messages: ctx.messages,
      tools: ctx.tools,
      tool_choice: ctx.tool_choice,
      model: ctx.client_config.model,
      metadata: %{}
    }
  end

  @doc """
  Build the opts list passed to the provider client. The
  `agent_pid` is threaded through so a test's per-agent
  mock client (e.g. `Nest.LLM.MockClient`) can find the
  queue scoped to this agent pid. The real OpenAI /
  Anthropic clients ignore unknown keys.
  """
  @spec build_opts(map()) :: keyword()
  def build_opts(ctx) do
    [
      base_url: ctx.client_config.base_url,
      api_key: ctx.client_config.api_key,
      receive_timeout: ctx.client_config.receive_timeout,
      agent_pid: ctx.agent_pid
    ]
  end

  @doc """
  Run a single streaming completion. Consumes the
  provider's event stream, dispatches canonical events to
  the supplied callbacks, and returns `{:ok, response}`
  on a clean stream or `{:error, term}` on a stream-level
  error.

  Callbacks is a map (see the `callbacks` type). The
  `should_stop/0` callback is consulted between events;
  when it returns `true` the stream halts and
  `request/2` returns `{:ok, nil}`.

  On a connection-level error (the client returns
  `{:error, reason}` rather than a stream), `on_error/1`
  is invoked and `request/2` returns `{:error, reason}`.
  """
  @spec request(map(), callbacks()) ::
          {:ok, RunResponse.t() | nil} | {:error, term()}
  def request(ctx, callbacks) do
    request = build_request(ctx)
    opts = build_opts(ctx)

    case ctx.client_config.client.run(request, opts) do
      {:ok, stream} ->
        consume(stream, callbacks)

      {:error, reason} ->
        if on_error = callbacks[:on_error], do: on_error.(reason)
        {:error, reason}
    end
  end

  @doc """
  Consume the streaming event envelope, dispatching to the
  consumer's callbacks. The `callbacks` is a map of
  2-arity (text/thinking + sent) and 1-arity functions;
  see `request/3` for the full callback list.

  Returns `{:ok, response}` on a clean stream (the consumer
  has been notified via `on_response/1`); `{:ok, nil}` if
  the stream halted cooperatively (no response to report);
  or `{:error, reason}` on a stream-level error (the
  consumer has been notified via `on_error/1`).

  The accumulator is the source of truth for parsed tool
  calls and usage. The `{:done, _}` event's
  `response.tool_calls` (when set) carries whatever the
  client decided to put there, which may be plain maps
  (mock) or `Nest.LLM.Tool` structs. We replace it with
  the accumulator's normalized `Nest.Messages.ToolCall`
  list so downstream consumers can pattern-match on the
  struct. `usage` is propagated from the accumulator too,
  since some clients (and the test mock) emit
  `{:usage, _}` events without echoing the value back into
  the `:done` response payload.
  """
  @type callbacks :: %{
          on_text: (String.t(), map() -> map()),
          on_thinking: (String.t(), map() -> map()),
          on_signature: (String.t() -> any()),
          on_response: (RunResponse.t() -> any()),
          on_error: (term() -> any()),
          should_stop: (-> boolean())
        }

  @spec consume(Enumerable.t(), callbacks()) ::
          {:ok, RunResponse.t() | nil} | {:error, term()}
  def consume(stream, callbacks) do
    stream_consumer = build_stream_consumer(callbacks)
    StreamConsumer.reduce(stream, stream_consumer) |> dispatch_reducer_result(callbacks)
  end

  defp build_stream_consumer(callbacks) do
    %StreamConsumer{
      on_text: callbacks[:on_text] || (& &1),
      on_thinking: callbacks[:on_thinking] || (& &1),
      on_signature: callbacks[:on_signature] || (& &1),
      should_stop: callbacks[:should_stop] || fn -> false end
    }
  end

  defp dispatch_reducer_result({acc, %RunResponse{} = response, nil, _sent}, callbacks) do
    normalized = normalize_response(response, acc)
    if on_response = callbacks[:on_response], do: on_response.(normalized)
    {:ok, normalized}
  end

  # Stream halted cooperatively (user clicked Stop). No
  # final response to report.
  defp dispatch_reducer_result({_acc, nil, nil, _sent}, _callbacks), do: {:ok, nil}

  defp dispatch_reducer_result({_acc, _response, error, _sent}, callbacks)
       when not is_nil(error) do
    if on_error = callbacks[:on_error], do: on_error.(error)
    {:error, error}
  end

  # Merge the accumulator's parsed tool calls and usage
  # into the final response. The accumulator is the
  # canonical source for these fields because some clients
  # (and the test mock) emit `{:usage, _}` and
  # `{:tool_call_start, _}` / `{:tool_call_delta, _}`
  # events without echoing the parsed values back into
  # the `{:done, _}` response payload.
  defp normalize_response(%RunResponse{} = response, acc) do
    finalized = Client.finalize(acc, response.model)

    %{
      response
      | tool_calls: finalized.tool_calls,
        text: response.text || finalized.text,
        thinking: response.thinking || finalized.thinking,
        thinking_signature: response.thinking_signature || finalized.thinking_signature,
        usage: response.usage || finalized.usage
    }
  end

  @doc """
  Format an HTTP error tuple as a user-facing error string.
  Centralized here so the runner's error path produces the
  same `[Source: ...]` tag as the Agent's other error
  sites.
  """
  @spec format_error(term()) :: String.t()
  def format_error({type, status, ""}), do: "Error: HTTP #{status}: #{type}"

  def format_error({type, status, body}),
    do: "Error: HTTP #{status}: #{type}\n#{truncate_body(body)}"

  def format_error(error), do: "Error: #{inspect(error)}"

  @body_truncate_bytes 500

  defp truncate_body(""), do: ""
  defp truncate_body(nil), do: ""

  defp truncate_body(body) when is_binary(body) do
    if String.length(body) > @body_truncate_bytes,
      do: String.slice(body, 0, @body_truncate_bytes) <> "\n...(truncated)",
      else: body
  end

  defp truncate_body(other), do: inspect(other)

  # Render a request's wire-format payload for the api_log
  # stream. Kept here (next to `build_request/1`) so the
  # wire format and the request shape evolve together.
  @doc false
  @spec format_request_payload(ClientConfig.t(), RunRequest.t(), keyword()) :: map()
  def format_request_payload(%ClientConfig{client: client} = _cc, request, opts) do
    client.format_request_payload(request, opts)
  end

  @doc false
  # Re-export of `Broadcasts.delta_text/4` so consumer
  # modules that need it don't have to alias `Broadcasts`
  # themselves. Cheap convenience.
  def delta_text(agent_id, message_index, content, chars_start) do
    Broadcasts.delta_text(agent_id, message_index, content, chars_start)
  end

  @doc false
  def delta_thinking(agent_id, message_index, content, chars_start) do
    Broadcasts.delta_thinking(agent_id, message_index, content, chars_start)
  end
end
