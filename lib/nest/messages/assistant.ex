defmodule Nest.Messages.Assistant do
  @moduledoc """
  Assistant message. Carries a list of `Part` structs in the
  order the LLM produced them (text, thinking, tool_use, refusal).
  Also carries the response-level metadata (usage, finish_reason,
  model) that the LLM client returned with the response. Those
  fields are persisted alongside `parts` in the jsonb `content`
  column so a restored agent can re-emit them on the next turn.
  """

  alias Nest.Messages.Message
  alias Nest.Messages.Part

  defstruct [
    :index,
    :parts,
    :usage,
    :finish_reason,
    :model,
    :timestamp,
    :metadata,
    :api_logs,
    :tokens
  ]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          parts: [Part.t()],
          # Token usage from the LLM response. `nil` for clients
          # that don't populate it (or for streaming responses
          # that arrived in pieces). Shape matches the wire
          # `usage` object: `%{input_tokens, output_tokens,
          # total_tokens, ...}`.
          usage: map() | nil,
          # LLM client-normalized finish reason
          # ("end_turn" / "tool_calls" / "max_tokens" / etc.).
          finish_reason: String.t() | nil,
          # The model the response was generated with. Useful
          # when the agent is configured to fall back across
          # models (the response may differ from the request's
          # model).
          model: String.t() | nil,
          timestamp: DateTime.t() | nil,
          # Free-form bag for client-specific data. Known keys
          # today: `"stopped_by_user"` (set by the stop handler
          # when finalizing a partial). Clients with
          # provider-specific payloads should add named fields
          # to this struct rather than reach into metadata.
          metadata: map() | nil,
          api_logs: [map()] | nil,
          # See `Nest.Messages.System.t()` for the full contract.
          tokens: non_neg_integer() | nil
        }

  @doc """
  Convert to JSON-compatible map for wire format.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = msg) do
    %{
      "index" => msg.index,
      "role" => "assistant",
      "parts" => Enum.map(msg.parts, &Part.to_json/1),
      "usage" => msg.usage,
      "finishReason" => msg.finish_reason,
      "model" => msg.model,
      "apiLogs" => Message.format_api_logs(msg.api_logs),
      "metadata" => stringify_metadata(msg.metadata)
    }
    |> Message.maybe_put_tokens(msg.tokens)
  end

  # The wire format uses string keys everywhere. Convert atom
  # keys in `metadata` (e.g. `:stopped_by_user` would become
  # `"stopped_by_user"` if we ever set it as such) and pass
  # string-keyed maps through unchanged. `nil` becomes `nil`.
  defp stringify_metadata(nil), do: nil

  defp stringify_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {k, v} -> {if(is_atom(k), do: Atom.to_string(k), else: k), v} end)
  end
end
