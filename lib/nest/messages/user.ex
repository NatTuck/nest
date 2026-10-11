defmodule Nest.Messages.User do
  @moduledoc """
  User message with text content.

  ## `origin` metadata

  A user message the human actually typed carries `metadata["origin"] ==
  "human"` (see `human_metadata/0`). The client's Ctrl/Cmd+Up recall list
  shows *only* such messages: peer deliveries, runtime notices and synthetic
  reminders are user-role rows too, and the filter is fail-closed — anything
  not marked `"human"` is excluded. `to_json/1` exposes the key only when
  present, so an untagged row's wire payload is unchanged.
  """

  alias Nest.Messages.Message
  alias Nest.Messages.Part

  # The metadata key/value marking a user message as the human's own words.
  @origin_key "origin"
  @human_origin "human"

  defstruct [:index, :parts, :timestamp, :metadata, :api_logs, :tokens]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          parts: [Part.t()],
          timestamp: DateTime.t() | nil,
          metadata: map() | nil,
          api_logs: [map()] | nil,
          # See `Nest.Messages.System.t()` for the full contract.
          tokens: non_neg_integer() | nil
        }

  @doc """
  The `metadata` marking a user message as typed by the human.

  Merge into the metadata of every user message built from human input:
  `ChatPipeline.handle_chat/3` (an idle turn) and the drained human path in
  `Nest.Agents.Agent.Inbox.build_drained_message/3` (a message sent while the
  agent was busy). Everything else stays untagged on purpose — the recall list
  includes a user row only when it carries this marker.
  """
  @spec human_metadata() :: map()
  def human_metadata, do: %{@origin_key => @human_origin}

  @doc """
  Convert to JSON-compatible map for wire format.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = msg) do
    %{
      "index" => msg.index,
      "role" => "user",
      "parts" => Enum.map(msg.parts, &Part.to_json/1),
      "mode" => msg.metadata && msg.metadata["mode"],
      "apiLogs" => Message.format_api_logs(msg.api_logs)
    }
    |> maybe_put_origin(msg.metadata)
    |> Message.maybe_put_tokens(msg.tokens)
  end

  # The `origin` key rides the wire only when the message carries it, so an
  # untagged (delivered, runtime, or legacy) row keeps today's payload shape.
  defp maybe_put_origin(json, %{@origin_key => origin}) when is_binary(origin),
    do: Map.put(json, @origin_key, origin)

  defp maybe_put_origin(json, _metadata), do: json
end
