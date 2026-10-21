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

  ## `commandOutputParts`: which parts are command output

  A row may hold more than one `Part.Text` (issue #139): a drained batch is one
  row holding several bodies, and a backgrounded command's notice splits into
  the prose around its output and the output itself. The text is unchanged —
  every consumer joins the parts with `""` — but the *browser* needs to know
  which of them to render as command output (fixed font, collapsed when long)
  rather than as markdown, which mangles `#`, `*`, `_`, backticks and indented
  lines.

  `command_output_metadata/1` names them: a list of **indexes into the row's
  `parts`**, carried in metadata as `"command_output_parts"` and exposed on the
  wire as `"commandOutputParts"`. It is a *rendering* fact about the row, and it
  rides metadata for one plain reason — `Part.Text` has no metadata field of its
  own, so there is nowhere on the part to put it. The key is omitted entirely
  when the list is empty, so every row that is not a backgrounded notice keeps
  exactly the payload shape it had.
  """

  alias Nest.Messages.Message
  alias Nest.Messages.Part
  alias Nest.Messages.Segment

  # The metadata key/value marking a user message as the human's own words.
  @origin_key "origin"
  @human_origin "human"
  @composed_key "composed"

  # The origin marking the runtime's compaction request.
  @compaction_origin "compaction"

  # The `mode` the request carries: the header's `mode:` clause, which is what
  # the client matches against to strip the header and render a badge instead.
  # The user sees what the row is rather than raw wire text.
  @compaction_mode "compact"

  # The metadata key naming the row's command-output parts (issue #139). The
  # wire spelling is this module's too (`to_json/1`), exactly as `origin` is.
  @command_output_key "command_output_parts"

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
  The metadata a user message carries for the `source` that produced it.

    * `:composed` — the human typed it in the composer. `origin: "human"` **and**
      `composed: true`; the recall list requires both, so a message the human
      did not type cannot reach it.
    * `:synthesized` — the human's words, produced by the UI rather than typed:
      a decision answer, an explain request. `origin: "human"` so the row is
      attributed to them in the header and to the model, but not recallable.
    * `false` — nobody's words: an `agents-spawn` `query` kickoff. No metadata.

  Any other value raises. The distinction is the whole point, so a call site
  that passes a bare `true` must fail loudly here rather than quietly lose the
  prompt from the recall list.
  """
  @spec source_metadata(:composed | :synthesized | false) :: map()
  def source_metadata(:composed), do: Map.put(human_metadata(), @composed_key, true)
  def source_metadata(:synthesized), do: human_metadata()
  def source_metadata(false), do: %{}

  def source_metadata(other),
    do: raise(ArgumentError, "unknown user-message source: #{inspect(other)}")

  @doc """
  The `metadata` marking a user message as the runtime's compaction request.

  The runtime is asking the model to summarise; the human did not type this.
  Merge into the metadata of the request message (`Nest.Tokens.Compactor`'s
  `render_suffix/2`), so the row is excluded from the recall list *and* from
  `MessageAppender.progress_message?/1` — it is not progress, and counting it
  as progress would disarm the consecutive-compaction loop breaker.

  The `"mode"` key is set too, and it is not cosmetic: it is the mode the row's
  header states (`Nest.Messages.Header`), and the client strips the header on
  render by matching its clause against this key. Without it the user reads the
  raw wire header.
  """
  @spec compaction_metadata() :: map()
  def compaction_metadata do
    %{@origin_key => @compaction_origin, "mode" => @compaction_mode}
  end

  @doc """
  The mode a compaction request row states — its header's clause and its badge.

  Not a mode the operator can select (`Nest.Modes` has `plan` and `act`): it
  marks the row as the runtime's compaction request, which is what the model's
  system prompt explains and what the client badges.
  """
  @spec compaction_mode() :: String.t()
  def compaction_mode, do: @compaction_mode

  @doc "The `origin` value marking the runtime's compaction request."
  @spec compaction_origin() :: String.t()
  def compaction_origin, do: @compaction_origin

  @doc """
  The metadata naming the row's command-output parts: the indexes into its
  `parts` whose text is a backgrounded shell command's output, to be rendered as
  output rather than as markdown (issue #139).

  The producer passes the row's segments in order — `{:text, …}` for prose,
  `{:output, …}` for command output (`Nest.Agents.Agent.Inbox.Render.parts/2`)
  — and only the indexes of the output ones are kept. Empty for a row with no
  command output, so an ordinary delivery carries no marker at all.

  `Nest.Agents.Agent.Inbox.Render.build_drained_message/3` is the only caller:
  it is the row's one writer, and this is that row's only statement of which
  parts are output.
  """
  @spec command_output_metadata([Segment.t()]) :: map()
  def command_output_metadata(parts) do
    case for {{:output, _text}, index} <- Enum.with_index(parts), do: index do
      [] -> %{}
      indexes -> %{@command_output_key => indexes}
    end
  end

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
    |> maybe_put_composed(msg.metadata)
    |> maybe_put_command_output_parts(msg.metadata)
    |> Message.maybe_put_tokens(msg.tokens)
  end

  # The `origin` key rides the wire only when the message carries it, so an
  # untagged (delivered, runtime, or legacy) row keeps today's payload shape.
  defp maybe_put_origin(json, %{@origin_key => origin}) when is_binary(origin),
    do: Map.put(json, @origin_key, origin)

  defp maybe_put_origin(json, _metadata), do: json

  # The second half of the recall filter, and the same rule: only when the row
  # carries it, so an untagged row's payload shape is unchanged. `origin` marks
  # the human's words; this marks the ones they typed.
  defp maybe_put_composed(json, %{@composed_key => true}), do: Map.put(json, @composed_key, true)
  defp maybe_put_composed(json, _metadata), do: json

  # The command-output indexes ride the wire only when there are some: an empty
  # list is the same fact as no marker, so a row with no command output omits the
  # key entirely rather than sending an empty one (issue #139).
  defp maybe_put_command_output_parts(json, %{@command_output_key => [_ | _] = indexes}),
    do: Map.put(json, "commandOutputParts", indexes)

  defp maybe_put_command_output_parts(json, _metadata), do: json
end
