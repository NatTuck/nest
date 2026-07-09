defmodule Nest.Agents.PersistedMessage do
  @moduledoc """
  Ecto schema for the `messages` table. One row per chat
  message (system, user, assistant, tool, or compaction).

  ## Append-only shape

  The table is append-only for its own rows: there are no
  UPDATEs against the `messages` rows themselves. Active-vs-history
  is a *view*, not a flag — `agents.last_compaction_index` is the
  boundary, and `Persistence.load_messages/1` returns the full
  ordered sequence (active + history + compaction markers).
  Partition into `state.chat_state.messages` (active) and
  `state.chat_state.history` (history) happens at agent-init
  time based on that pointer.

  ## `content` shape

  The `content` column is a jsonb map that mirrors the runtime
  `Message` struct's wire format (see `Message.to_json/1`):

      %{
        "parts" => [
          %{"kind" => "text", "text" => "..."},
          %{"kind" => "tool_use", "id" => "...", "name" => "...",
           "arguments" => %{...}},
          ...
        ],
        # assistant only:
        "usage" => %{...},
        "finishReason" => "...",
        "model" => "...",
        "metadata" => %{...},
        # assistant + system:
        "apiLogs" => [...],
        # optional:
        "tokens" => 1234
      }

  ## Selective `apiLogs` persistence

  The `apiLogs` key is written only for `:assistant` (response
  logs — small) and `:system` (typically empty, forward compat).
  `:user`/`:tool` rows DO NOT carry `apiLogs`; those messages'
  request payloads are rebuilt on restore via
  `Nest.Agents.Agent.Restore` (the rebuild uses the same
  `format_request_payload/2` the live path uses, so the wire
  format is identical to what the LLM would have received).

  `to_runtime/1` reads `content["apiLogs"] || []` for the
  additive round-trip; legacy rows that pre-date this change
  simply have no `apiLogs` key and read back as `[]`.

  Compaction messages use the same `content` column with a
  `parts: []` list and the special `compaction_archived_count` /
  `compaction_occurred_at` columns.

  ## Round-trip

  `from_runtime/2` accepts a `{role, %_{}}` tagged tuple (the
  canonical `Message.t()` shape) and produces a changeset-ready
  attrs map. `to_runtime/1` is the inverse: reads a row, walks
  the `content.parts` list, and builds the appropriate runtime
  struct.

  The persistence layer never translates the wire format — the
  runtime structs and the persisted jsonb use the same keys.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Nest.Messages.Assistant
  alias Nest.Messages.Compaction
  alias Nest.Messages.Message
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User

  @type t :: %__MODULE__{
          id: integer() | nil,
          agent_id: integer() | nil,
          message_index: non_neg_integer() | nil,
          role: String.t() | nil,
          content: map(),
          metadata: map() | nil,
          inserted_at: DateTime.t() | nil,
          compaction_archived_count: non_neg_integer() | nil,
          compaction_occurred_at: DateTime.t() | nil,
          compaction_tokens_compacted: non_neg_integer() | nil,
          compaction_tokens_compacted_to: non_neg_integer() | nil
        }

  @primary_key {:id, :id, autogenerate: true}
  schema "messages" do
    belongs_to :agent, Nest.Agents.PersistedAgent,
      foreign_key: :agent_id,
      references: :id

    field :message_index, :integer
    field :role, :string
    field :content, :map
    field :metadata, :map
    field :compaction_archived_count, :integer
    field :compaction_occurred_at, :utc_datetime
    # Token-count stats for the compaction boundary the
    # marker represents. Both nullable: nil for non-compaction
    # rows and for pre-existing compaction marker rows that
    # pre-date this migration. The UI renders absent stats as
    # "Context compacted (N archived)" without a token count.
    field :compaction_tokens_compacted, :integer
    field :compaction_tokens_compacted_to, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Cast attributes for insert. `:agent_id`, `:message_index`,
  `:role`, and `:content` are required.
  """
  def changeset(source, params) do
    source
    |> cast(
      params,
      [
        :agent_id,
        :message_index,
        :role,
        :content,
        :metadata,
        :compaction_archived_count,
        :compaction_occurred_at,
        :compaction_tokens_compacted,
        :compaction_tokens_compacted_to
      ]
    )
    |> validate_required([:agent_id, :message_index, :role, :content])
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:message_index, name: :messages_agent_id_message_index_index)
  end

  @doc """
  Build a changeset-ready attrs map from a runtime message tuple.

  The runtime tuple is the canonical `Message.t()` shape:
  `{:system, %System{}}`, `{:user, %User{}}`, etc. The
  `compaction` variant carries no `parts` and is serialized as
  a `role: "compaction"` row with `compaction_archived_count`
  and `compaction_occurred_at` populated.

  `agent_id` is the owning agent's integer `id` (the FK column).
  `index` is the message's `index` field (read off the inner
  struct); the caller's Agent process has already stamped it.
  The `message_index` column must be unique per agent.
  """
  @spec from_runtime(integer(), Message.t()) :: map()
  def from_runtime(agent_id, {role, struct}) do
    base = %{
      agent_id: agent_id,
      message_index: struct.index,
      role: Atom.to_string(role),
      content: serialize_content(role, struct),
      metadata: struct.metadata
    }

    case role do
      :compaction ->
        base
        |> Map.put(:compaction_archived_count, struct.archived_count)
        |> Map.put(:compaction_occurred_at, struct.occurred_at)
        |> maybe_put_compaction_tokens(struct)

      _ ->
        base
    end
  end

  # Token stats are computed at compaction time and stored on
  # the marker row. They're nil when the marker was created
  # before this migration ran (legacy rows), so the cast is
  # conditional — `nil` means "don't write the column".
  defp maybe_put_compaction_tokens(map, %{tokens_compacted: nil, tokens_compacted_to: nil}),
    do: map

  defp maybe_put_compaction_tokens(map, %Nest.Messages.Compaction{
         tokens_compacted: tokens_compacted,
         tokens_compacted_to: tokens_compacted_to
       }) do
    map
    |> Map.put(:compaction_tokens_compacted, tokens_compacted)
    |> Map.put(:compaction_tokens_compacted_to, tokens_compacted_to)
  end

  # Walk the runtime struct's `parts` list and produce the
  # jsonb map we persist. The keys are the same as the wire
  # format produced by `Message.to_json/1`, so reading the
  # data back via `to_runtime/1` is a near-trivial map walk.
  #
  # `:assistant` and `:system` rows ALWAYS carry the `apiLogs`
  # key (even when empty). `:user`/`:tool` rows DON'T carry it;
  # their request payloads are rebuilt by
  # `Nest.Agents.Agent.Restore` on agent-init to keep storage
  # from growing O(N²) across compaction cycles.
  defp serialize_content(:compaction, _struct), do: %{"parts" => []}

  defp serialize_content(:system, %System{} = struct) do
    %{"parts" => Enum.map(struct.parts || [], &Part.to_json/1)}
    |> Map.put("apiLogs", Message.format_api_logs(struct.api_logs))
    |> maybe_put_tokens(struct.tokens)
  end

  defp serialize_content(role, struct) when role in [:user, :tool] do
    %{"parts" => Enum.map(struct.parts || [], &Part.to_json/1)}
    |> maybe_put_tokens(struct.tokens)
  end

  defp serialize_content(:assistant, %Assistant{} = struct) do
    %{"parts" => Enum.map(struct.parts || [], &Part.to_json/1)}
    |> maybe_put("usage", struct.usage)
    |> maybe_put("finishReason", struct.finish_reason)
    |> maybe_put("model", struct.model)
    |> Map.put("apiLogs", Message.format_api_logs(struct.api_logs))
    |> maybe_put("metadata", stringify_keys(struct.metadata))
    |> maybe_put_tokens(struct.tokens)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_tokens(map, nil), do: map

  defp maybe_put_tokens(map, n) when is_integer(n) and n >= 0,
    do: Map.put(map, "tokens", n)

  # Convert atom-keyed metadata to string keys so the jsonb
  # value is uniform with the rest of `content`. The
  # reverse direction is in `stringify_keys/1` below for
  # `to_runtime/1`.
  defp stringify_keys(nil), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {if(is_atom(k), do: Atom.to_string(k), else: k), v} end)
  end

  @doc """
  Build a runtime `Message.t()` tuple from a persisted row.

  The inverse of `from_runtime/2`. The `id` and `inserted_at`
  fields are read off the row but not propagated to the
  runtime struct (the runtime doesn't track them).
  """
  @spec to_runtime(t()) :: Message.t()
  def to_runtime(%__MODULE__{role: "system", content: content, metadata: metadata} = row) do
    {:system,
     %System{
       index: row.message_index,
       parts: parts_from_json(content),
       timestamp: row.inserted_at,
       metadata: metadata,
       # `:system` rows now always carry the `apiLogs` key in
       # `content` (typical value: `[]`). Legacy rows that pre-date
       # this change have no key; the `||` default keeps them
       # round-trip-safe.
       api_logs: api_logs_from(content),
       tokens: content["tokens"]
     }}
  end

  def to_runtime(%__MODULE__{role: "user", content: content, metadata: metadata} = row) do
    {:user,
     %User{
       index: row.message_index,
       parts: parts_from_json(content),
       timestamp: row.inserted_at,
       metadata: metadata,
       # `:user` rows DO NOT carry `apiLogs` in their `content`
       # (rebuilt on restore by `Nest.Agents.Agent.Restore` to
       # keep the table from growing O(N²)). The runtime field
       # starts empty here; the rebuild populates it after
       # `seed_from_db/3` runs in `Agent.init/1`.
       api_logs: [],
       tokens: content["tokens"]
     }}
  end

  def to_runtime(%__MODULE__{role: "assistant", content: content, metadata: metadata} = row) do
    {:assistant,
     %Assistant{
       index: row.message_index,
       parts: parts_from_json(content),
       usage: content["usage"],
       finish_reason: content["finishReason"],
       model: content["model"],
       timestamp: row.inserted_at,
       metadata: metadata,
       api_logs: api_logs_from(content),
       tokens: content["tokens"]
     }}
  end

  def to_runtime(%__MODULE__{role: "tool", content: content, metadata: metadata} = row) do
    {:tool,
     %Tool{
       index: row.message_index,
       parts: parts_from_json(content),
       timestamp: row.inserted_at,
       metadata: metadata,
       api_logs: [],
       tokens: content["tokens"]
     }}
  end

  def to_runtime(%__MODULE__{
        role: "compaction",
        message_index: index,
        compaction_archived_count: count,
        compaction_occurred_at: occurred_at,
        compaction_tokens_compacted: tokens_compacted,
        compaction_tokens_compacted_to: tokens_compacted_to
      }) do
    {:compaction,
     %Compaction{
       index: index,
       archived_count: count || 0,
       tokens_compacted: tokens_compacted,
       tokens_compacted_to: tokens_compacted_to,
       occurred_at: occurred_at,
       metadata: nil
     }}
  end

  # Walk the jsonb `parts` list and build the appropriate
  # runtime Part structs. Unknown / unrecognized part kinds
  # are silently dropped (a corrupt row shouldn't crash the
  # restore path).
  defp parts_from_json(%{"parts" => parts}) when is_list(parts) do
    parts
    |> Enum.map(&Part.from_json/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parts_from_json(_), do: []

  # Read the `apiLogs` key from the persisted content jsonb. When
  # the row pre-dates the selective api_log persistence change
  # (no key), or when the value is malformed (`nil`, non-list),
  # default to `[]`.
  #
  # The persisted shape uses string keys (jsonb round-trips through
  # `Message.format_api_logs/1`, which `to_string`s the `type`
  # value for the wire format). The live path uses atom keys
  # (`Broadcasts.api_log/4` builds a `%{id: ..., timestamp: ...,
  # type: ..., payload: ...}` struct). Other code paths in the
  # agent read `log.type == :request` directly, so we re-atomize
  # keys AND the `type` value here so the in-memory shape is
  # uniform regardless of whether the message originated live
  # or via DB restore.
  defp api_logs_from(%{"apiLogs" => api_logs}) when is_list(api_logs),
    do: Enum.map(api_logs, &atomize_api_log/1)

  defp api_logs_from(_), do: []

  defp atomize_api_log(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      key = if(is_binary(k), do: String.to_existing_atom(k), else: k)
      value = rehydrate_value(key, v)
      {key, value}
    end)
  end

  defp atomize_api_log(other), do: other

  # The wire format stringified `:request`/`:response`. Undo
  # that here for the `type` field so post-restore runtime
  # code reads the canonical atom.
  defp rehydrate_value(:type, "request"), do: :request
  defp rehydrate_value(:type, "response"), do: :response
  defp rehydrate_value(_key, value), do: value
end
