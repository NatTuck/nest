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

  One non-human origin is *named*, because more than presentation depends on
  it: `"compaction"` marks the runtime's compaction request (see
  `compaction_metadata/0`). It is a `user` row because that is what every
  provider's wire format can carry, but it is **not** progress and must not
  reset the consecutive-compaction counter — see
  `Nest.Agents.Agent.MessageAppender.progress_message?/1`.
  """

  alias Nest.Messages.Message
  alias Nest.Messages.Part

  # The metadata key/value marking a user message as the human's own words.
  @origin_key "origin"
  @human_origin "human"

  # The origin marking the runtime's compaction request.
  @compaction_origin "compaction"

  # The `mode` the request carries, matching the `[mode: compact]` tag
  # `CompactionProbeSupport.compaction_suffix/2` puts on the row's first line.
  # The client strips that tag by matching it against this key and renders a
  # badge instead, so the user sees what the row is rather than raw wire text.
  @compaction_mode "compact"

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
  The `metadata` marking a user message as the runtime's compaction request.

  The runtime is asking the model to summarise; the human did not type this.
  Merge into the metadata of the request message (`Nest.Tokens.Compactor`'s
  `render_suffix/2`), so the row is excluded from the recall list *and* from
  `MessageAppender.progress_message?/1` — it is not progress, and counting it
  as progress would disarm the consecutive-compaction loop breaker.

  The `"mode"` key is set too, and it is not cosmetic: the row's text begins
  with the `[mode: compact]` tag, and the client strips that tag on render by
  matching it against this key. Without it the user reads the raw wire tag.
  """
  @spec compaction_metadata() :: map()
  def compaction_metadata do
    %{@origin_key => @compaction_origin, "mode" => @compaction_mode}
  end

  @doc "The `origin` value marking the runtime's compaction request."
  @spec compaction_origin() :: String.t()
  def compaction_origin, do: @compaction_origin

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
