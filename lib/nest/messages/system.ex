defmodule Nest.Messages.System do
  @moduledoc "System message with configuration/instructions"

  alias Nest.Messages.Message
  alias Nest.Messages.Part

  defstruct [:index, :parts, :timestamp, :metadata, :api_logs, :tokens]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          parts: [Part.t()],
          timestamp: DateTime.t() | nil,
          metadata: map() | nil,
          api_logs: [map()] | nil,
          # Total tokens (input + cache_read + cache_creation) the
          # LLM consumed when this message was the LAST in its input.
          # `nil` when no LLM call has reported tokens for a
          # conversation ending at this message (typical for the
          # initial system prompt before any user turn). Populated
          # by `LLMStreamHandler.mark_last_message_tokens/2` after
          # every assistant response. Read by
          # `Nest.Tokens.ConversationSize.size/1` to derive the
          # current conversation size without re-estimating the
          # already-tokenized prefix.
          tokens: non_neg_integer() | nil
        }

  @doc """
  Convert to JSON-compatible map for wire format.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = msg) do
    %{
      "index" => msg.index,
      "role" => "system",
      "parts" => Enum.map(msg.parts, &Part.to_json/1),
      "mode" => msg.metadata && msg.metadata["mode"],
      "apiLogs" => Message.format_api_logs(msg.api_logs)
    }
    |> Message.maybe_put_tokens(msg.tokens)
  end
end
