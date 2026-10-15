defmodule Nest.Messages.Tool do
  @moduledoc """
  Tool response message. Carries `Part.ToolResult` structs
  (one per tool call that completed in the LLM's batch).
  """

  alias Nest.Messages.Message
  alias Nest.Messages.Part

  defstruct [:index, :parts, :timestamp, :metadata, :api_logs, :tokens]

  # The `origin` marking the runtime's interrupted-tool heal — see
  # `heal_metadata/0`.
  @heal_origin "heal"

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          parts: [Part.ToolResult.t()],
          timestamp: DateTime.t() | nil,
          metadata: map() | nil,
          api_logs: [map()] | nil,
          tokens: non_neg_integer() | nil
        }

  @doc """
  Convert to JSON-compatible map for wire format.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = msg) do
    %{
      "index" => msg.index,
      "role" => "tool",
      "parts" => Enum.map(msg.parts, &Part.to_json/1),
      "apiLogs" => Message.format_api_logs(msg.api_logs)
    }
    |> Message.maybe_put_tokens(msg.tokens)
  end

  @doc """
  The `metadata` marking a tool row as the runtime's *heal* rather than a
  tool the model actually called.

  `Nest.Messages.MessageList.interrupted_tool_result/1` builds it to answer a
  `tool_use` that will never complete, and the refused-batch path appends it
  immediately before staging a compaction request. It must not count as
  progress in `MessageAppender.progress_message?/1` for the same reason the
  request itself must not: it is emitted on every attempt, so counting it
  would reset `@max_consecutive_compactions` on every attempt and disarm the
  only bound on a compaction that keeps failing.

  Like the request row's marker, this is internal: `to_json/1` does not emit
  `metadata`, so the wire payload is unchanged.
  """
  @spec heal_metadata() :: map()
  def heal_metadata, do: %{"origin" => @heal_origin}

  @doc "The `origin` value marking the runtime's interrupted-tool heal."
  @spec heal_origin() :: String.t()
  def heal_origin, do: @heal_origin
end
