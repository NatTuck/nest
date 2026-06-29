defmodule Nest.Agents.PersistedMessage do
  @moduledoc """
  Ecto schema for the `messages` table. One row per chat
  message (system, user, assistant, tool, or compaction).

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
        "metadata" => %{...}
      }

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
          agent_id: String.t() | nil,
          message_index: non_neg_integer() | nil,
          role: String.t() | nil,
          content: map(),
          metadata: map() | nil,
          inserted_at: DateTime.t() | nil,
          archived_at: DateTime.t() | nil,
          compaction_archived_count: non_neg_integer() | nil,
          compaction_occurred_at: DateTime.t() | nil
        }

  @primary_key {:id, :bigserial}
  @primary_key {:id, :id, autogenerate: true}
  schema "messages" do
    belongs_to :agent, Nest.Agents.PersistedAgent,
      foreign_key: :agent_id,
      references: :id,
      type: :string

    field :message_index, :integer
    field :role, :string
    field :content, :map
    field :metadata, :map
    field :archived_at, :utc_datetime
    field :compaction_archived_count, :integer
    field :compaction_occurred_at, :utc_datetime

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
        :archived_at,
        :compaction_archived_count,
        :compaction_occurred_at
      ]
    )
    |> validate_required([:agent_id, :message_index, :role, :content])
    |> foreign_key_constraint(:agent_id)
  end

  @doc """
  Build a changeset-ready attrs map from a runtime message tuple.

  The runtime tuple is the canonical `Message.t()` shape:
  `{:system, %System{}}`, `{:user, %User{}}`, etc. The
  `compaction` variant carries no `parts` and is serialized as
  a `role: "compaction"` row with `compaction_archived_count`
  and `compaction_occurred_at` populated.

  `agent_id` is the owning agent's string id. `index` is the
  message's `index` field (read off the inner struct); the
  caller's Agent process has already stamped it. The
  `message_index` column must be unique per agent.
  """
  @spec from_runtime(String.t(), Message.t()) :: map()
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
        Map.merge(base, %{
          compaction_archived_count: struct.archived_count,
          compaction_occurred_at: struct.occurred_at
        })

      _ ->
        base
    end
  end

  # Walk the runtime struct's `parts` list and produce the
  # jsonb map we persist. The keys are the same as the wire
  # format produced by `Message.to_json/1`, so reading the
  # data back via `to_runtime/1` is a near-trivial map walk.
  defp serialize_content(:compaction, _struct), do: %{"parts" => []}

  defp serialize_content(role, struct) when role in [:system, :user, :tool] do
    %{"parts" => Enum.map(struct.parts || [], &Part.to_json/1)}
  end

  defp serialize_content(:assistant, %Assistant{} = struct) do
    %{"parts" => Enum.map(struct.parts || [], &Part.to_json/1)}
    |> maybe_put("usage", struct.usage)
    |> maybe_put("finishReason", struct.finish_reason)
    |> maybe_put("model", struct.model)
    |> maybe_put("metadata", stringify_keys(struct.metadata))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
       api_logs: []
     }}
  end

  def to_runtime(%__MODULE__{role: "user", content: content, metadata: metadata} = row) do
    {:user,
     %User{
       index: row.message_index,
       parts: parts_from_json(content),
       timestamp: row.inserted_at,
       metadata: metadata,
       api_logs: []
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
       api_logs: []
     }}
  end

  def to_runtime(%__MODULE__{role: "tool", content: content, metadata: metadata} = row) do
    {:tool,
     %Tool{
       index: row.message_index,
       parts: parts_from_json(content),
       timestamp: row.inserted_at,
       metadata: metadata,
       api_logs: []
     }}
  end

  def to_runtime(%__MODULE__{
        role: "compaction",
        message_index: index,
        compaction_archived_count: count,
        compaction_occurred_at: occurred_at
      }) do
    {:compaction,
     %Compaction{
       index: index,
       archived_count: count || 0,
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
end
