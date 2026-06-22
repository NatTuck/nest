defmodule Nest.LLM.StreamConsumer do
  @moduledoc """
  Shared canonical-event-stream reducer for the LLM consumer
  paths (`Nest.Agents.Agent.LLMRunner.consume_new_stream/4`
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
          on_signature: (term() -> any())
        }

  defstruct on_text: nil, on_thinking: nil, on_signature: nil

  @doc """
  Run the reducer over `stream` and return
  `{acc, response, error, sent}`.

  * `acc` is the live `Client.accumulator()`.
  * `response` is the `RunResponse` set by `{:done, _}`,
    or `nil` if the stream ended without one.
  * `error` is the error reason set by `{:error, _}`, or
    `nil`.
  * `sent` is the chars-counter state — useful for
    delta-broadcasting and the `consume_new_stream` caller.
  """
  @spec reduce(Enumerable.t(), t()) :: {Client.accumulator(), term() | nil, term() | nil, sent()}
  def reduce(stream, %__MODULE__{} = consumer) do
    initial = {Client.new_accumulator(), nil, nil, %{chars: 0, thinking_chars: 0}}
    Enum.reduce(stream, initial, fn event, acc -> dispatch(event, acc, consumer) end)
  end

  defp dispatch({:text, text}, {acc, response, error, sent}, consumer) do
    new_sent = consumer.on_text.(text, sent)
    {Client.accumulate(acc, {:text, text}), response, error, new_sent}
  end

  defp dispatch({:thinking, text}, {acc, response, error, sent}, consumer) do
    new_sent = consumer.on_thinking.(text, sent)
    {Client.accumulate(acc, {:text, text}), response, error, new_sent}
  end

  defp dispatch({:tool_call_start, event}, {acc, response, error, sent}, _consumer) do
    {Client.accumulate(acc, {:tool_call_start, event}), response, error, sent}
  end

  defp dispatch({:tool_call_delta, event}, {acc, response, error, sent}, _consumer) do
    {Client.accumulate(acc, {:tool_call_delta, event}), response, error, sent}
  end

  defp dispatch({:thinking_signature, sig}, {acc, response, error, sent}, consumer) do
    consumer.on_signature.(sig)
    {Client.accumulate(acc, {:thinking, sig}), response, error, sent}
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
