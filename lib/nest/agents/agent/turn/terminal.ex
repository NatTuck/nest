defmodule Nest.Agents.Agent.Turn.Terminal do
  @moduledoc """
  Pure builders for a turn's terminal recovery.

  `Turn.Executor` (the only place effects happen) uses one
  implementation of the
  "finalize the partial / heal the tail / build the parent payload"
  logic without any of it living outside the executor's call graph.

  Every function here is pure: it reads Agent state and returns messages,
  metadata, or payloads. The executor performs the appends, broadcasts,
  and casts.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Repair
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Streaming

  @doc "Metadata stamped on a user-stop terminal recovery."
  @spec stopped_metadata() :: map()
  def stopped_metadata, do: %{"stopped_by_user" => true}

  @doc "Metadata stamped on an error terminal recovery."
  @spec error_metadata() :: map()
  def error_metadata, do: %{"error" => true}

  @doc """
  The terminal recovery messages for the current partial tail. A streamed
  partial wins when the tail is not already an assistant; otherwise the
  repair decision heals the wire sequence.
  """
  @spec recovery_messages(Agent.t(), map()) :: [term()]
  def recovery_messages(state, metadata) do
    messages = state.chat_state.messages

    case partial_message(state.live.streaming_acc, metadata) do
      nil ->
        heal_tail(messages, metadata)

      partial ->
        case MessageList.last_wire_role(messages) do
          :assistant -> heal_tail(messages, metadata)
          _ -> [partial]
        end
    end
  end

  defp heal_tail(messages, metadata) do
    {:repair, repair} =
      Repair.decide(:terminal, messages, MessageList.continuation_prompt())

    Enum.map(repair, &tag_metadata(&1, metadata))
  end

  defp partial_message(nil, _metadata), do: nil

  defp partial_message(acc, metadata) do
    case Streaming.partial_message(acc, metadata) do
      {:assistant, %Assistant{parts: []}} -> nil
      partial -> partial
    end
  end

  defp tag_metadata({:assistant, %Assistant{} = msg}, metadata),
    do: {:assistant, %{msg | metadata: metadata}}

  defp tag_metadata(other, _metadata), do: other

  @doc """
  The assistant message for a stream-error terminal: whatever streamed,
  plus the error text, tagged `error`. A nil accumulator degrades to an
  error-only message.
  """
  @spec error_assistant_message(Agent.t(), String.t()) :: {:assistant, Assistant.t()}
  def error_assistant_message(state, error_msg) do
    error_part = %Nest.Messages.Part.Text{text: "\n\n" <> error_msg}

    case state.live.streaming_acc do
      %Streaming.AssistantAccumulator{} = acc ->
        {:assistant, partial} = Streaming.partial_message(acc, %{"error" => true})
        {:assistant, %{partial | parts: partial.parts ++ [error_part]}}

      _ ->
        {:assistant,
         %Assistant{
           index: nil,
           timestamp: DateTime.utc_now(),
           parts: [error_part],
           api_logs: [],
           metadata: %{"error" => true}
         }}
    end
  end

  @doc "The last assistant text in the active conversation, or `\"\"`."
  @spec last_assistant_text(Agent.t()) :: String.t()
  def last_assistant_text(state) do
    MessageList.last_assistant_text(state.chat_state.messages)
  end

  @doc "The `{:child_completed, ...}` payload a parent receives on clean idle."
  @spec parent_completion(Agent.t()) :: {:child_completed, String.t(), String.t(), map()}
  def parent_completion(state) do
    usage =
      Broadcasts.total_usage(
        state.llm_metrics.usage_totals,
        state.llm_metrics.descendant_usage
      )

    {:child_completed, state.name, last_assistant_text(state), usage}
  end

  @doc "The `{:child_failed, ...}` payload a parent receives on failure."
  @spec parent_failure(Agent.t(), term()) :: {:child_failed, String.t(), term()}
  def parent_failure(state, reason), do: {:child_failed, state.name, reason}

  @doc "Normalize a crash reason for the parent notification."
  @spec crash_reason(term()) :: term()
  def crash_reason(%{__exception__: true} = exception),
    do: {:crashed, Exception.message(exception)}

  def crash_reason(other), do: {:crashed, inspect(other)}

  @doc "True for the benign `GenServer.call`-to-a-dead-process crashes."
  @spec benign_crash?(term()) :: boolean()
  def benign_crash?(%RuntimeError{message: message}) do
    String.contains?(message, "{GenServer, :call,") and
      (String.contains?(message, ":normal,") or
         String.contains?(message, ":noproc,") or
         String.contains?(message, ":shutdown,"))
  end

  def benign_crash?(_), do: false

  @doc "Format a crash with a short stacktrace snippet for the UI error."
  @spec format_crash(term(), list()) :: String.t()
  def format_crash(exception, stacktrace) do
    formatted = Exception.format(:error, exception, stacktrace)
    formatted |> take_frames(5) |> truncate(2000)
  end

  defp take_frames(formatted, n) do
    lines = String.split(formatted, "\n")

    {header, frames} =
      Enum.split_while(lines, fn line -> not String.starts_with?(line, "    ") end)

    Enum.take(frames, n)
    |> Kernel.++(if(length(frames) > n, do: ["    ..."], else: []))
    |> Enum.concat(header)
    |> Enum.join("\n")
  end

  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: binary_part(s, 0, max) <> "\n...(truncated)"
end
