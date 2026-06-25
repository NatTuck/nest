defmodule Nest.LLM.StreamConsumer do
  @moduledoc """
  Shared canonical-event-stream reducer for the LLM consumer
  paths (`Nest.Agents.Agent.ChatTurn.HTTPWorker.run/2`
  and `Nest.Agents.Agent.Compaction.consume_quietly/2`).

  Walks the canonical event stream produced by the LLM
  clients, accumulates the response, and invokes a small
  set of hooks for the events whose handling differs
  between consumers (text deltas, thinking deltas, and
  thinking signatures).

  The other event types (`{:tool_call_start, _}`,
  `{:tool_call_delta, _}`, `{:usage, _}`,
  `{:finish_reason, _}`, `{:refusal, _}`, `{:done, _}`,
  `{:error, _}`) are handled identically by both consumers
  and are accumulated inline.
  """

  alias Nest.LLM.Client

  @type sent :: %{chars: non_neg_integer(), thinking_chars: non_neg_integer()}

  @type t :: %__MODULE__{
          on_text: (String.t(), sent() -> sent()),
          on_thinking: (String.t(), sent() -> sent()),
          on_signature: (term() -> any()),
          # Optional cooperative-stop callback. Invoked at the
          # start of every event in the stream; return `true`
          # to halt the stream with a `nil` response (so the
          # caller can detect a user-initiated stop). The
          # default is `:undefined` (never stop). This is the
          # way the real consumer is interrupted when the
          # agent is using a non-mailbox-backed stream (e.g.
          # the mock client in tests, which iterates a list
          # synchronously) — for mailbox-backed streams the
          # `{:stop_chat, from}` clause in the SSE consumer
          # is the primary interrupt path.
          should_stop: (term() -> boolean()) | nil
        }

  defstruct on_text: nil,
            on_thinking: nil,
            on_signature: nil,
            should_stop: nil

  @doc """
  Run the reducer over `stream` and return
  `{acc, response, error, sent}`.

  * `acc` is the live `Client.accumulator()`.
  * `response` is the `RunResponse` set by `{:done, _}`,
    or `nil` if the stream ended without one (e.g. halted
    via `{:stop_chat, _}` from the stop handler or the
    cooperative `should_stop` callback).
  * `error` is the error reason set by `{:error, _}`, or
    `nil`.
  * `sent` is the chars-counter state — useful for
    delta-broadcasting and the `consume_new_stream` caller.
  """
  @spec reduce(Enumerable.t(), t()) ::
          {Client.accumulator(), term() | nil, term() | nil, sent()}
  def reduce(stream, %__MODULE__{} = consumer) do
    initial = {Client.new_accumulator(), nil, nil, %{chars: 0, thinking_chars: 0}}

    Enum.reduce_while(stream, initial, fn event, acc ->
      if stop_requested?(consumer, acc) do
        {:halt, acc}
      else
        {:cont, dispatch(event, acc, consumer)}
      end
    end)
  end

  # Check if the consumer wants to stop. When `should_stop` is
  # `nil` (the default), we check the chat task's mailbox for a
  # `{:stop_chat, from}` message — that's how the HTTP worker
  # is interrupted for non-mailbox-backed streams like the test
  # mock client. The `should_stop` callback is an additional hook
  # for non-process-mailbox backends (e.g. when the test wants
  # to inject a stop without going through the chat task's
  # mailbox).
  defp stop_requested?(%__MODULE__{should_stop: fun}, acc) when is_function(fun, 1) do
    fun.(acc)
  end

  defp stop_requested?(%__MODULE__{should_stop: fun}, _acc) when is_function(fun, 0) do
    fun.()
  end

  defp stop_requested?(%__MODULE__{should_stop: nil}, _acc) do
    receive do
      {:stop_chat, from} ->
        send(from, :stopped)
        true
    after
      0 -> false
    end
  end

  @doc """
  Dispatch a single canonical event against the reducer state.
  Public for testability; the dispatch logic is also inlined
  into `reduce/2` via the private `dispatch/3` clauses.
  """
  @spec dispatch_step(term(), {Client.accumulator(), term() | nil, term() | nil, sent()}, t()) ::
          {Client.accumulator(), term() | nil, term() | nil, sent()}
  def dispatch_step(event, acc, consumer), do: dispatch(event, acc, consumer)

  defp dispatch({:text, text}, {acc, response, error, sent}, consumer) do
    new_sent = consumer.on_text.(text, sent)
    {Client.accumulate(acc, {:text, text}), response, error, new_sent}
  end

  defp dispatch({:thinking, text}, {acc, response, error, sent}, consumer) do
    new_sent = consumer.on_thinking.(text, sent)
    {Client.accumulate(acc, {:thinking, text}), response, error, new_sent}
  end

  defp dispatch({:tool_call_start, event}, {acc, response, error, sent}, _consumer) do
    {Client.accumulate(acc, {:tool_call_start, event}), response, error, sent}
  end

  defp dispatch({:tool_call_delta, event}, {acc, response, error, sent}, _consumer) do
    {Client.accumulate(acc, {:tool_call_delta, event}), response, error, sent}
  end

  defp dispatch({:thinking_signature, sig}, {acc, response, error, sent}, consumer) do
    consumer.on_signature.(sig)
    {Client.accumulate(acc, {:thinking_signature, sig}), response, error, sent}
  end

  defp dispatch({:usage, usage}, {acc, response, error, sent}, _consumer) do
    {Client.accumulate(acc, {:usage, usage}), response, error, sent}
  end

  defp dispatch({:finish_reason, reason}, {acc, response, error, sent}, _consumer) do
    {Client.accumulate(acc, {:finish_reason, reason}), response, error, sent}
  end

  defp dispatch({:refusal, text}, {acc, response, error, sent}, _consumer) do
    {Client.accumulate(acc, {:refusal, text}), response, error, sent}
  end

  defp dispatch({:done, %{response: r}}, {acc, _response, error, sent}, _consumer) do
    {acc, r, error, sent}
  end

  defp dispatch({:error, reason}, {acc, response, _error, sent}, _consumer) do
    {acc, response, reason, sent}
  end

  # Unknown events are silently accumulated so the mock
  # client and any future event types don't crash the
  # consumer. The `Client.accumulate/2` accumulator is
  # tolerant of unknown events.
  defp dispatch(other, {acc, response, error, sent}, _consumer) do
    {Client.accumulate(acc, other), response, error, sent}
  end
end
