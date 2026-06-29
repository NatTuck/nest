defmodule Nest.Persistence do
  @moduledoc """
  Wrapper around the DB-touching parts of starting an Agent
  and the agent + message persistence layer.

  Centralises the "load and start" pattern so test code and
  production code call the same function. Tests rely on the
  test process already owning a sandboxed connection (see
  `Nest.DataCase.setup_sandbox/1`); production uses the global
  Ecto pool. Either way, the DB read happens in the calling
  process, which lets the Agent's `init/1` skip DB work and
  inherit `$callers` for subsequent handler DB writes.

  ## Why this exists

  The Agent's `init/1` historically called
  `Vocations.get_vocation/1` itself. That worked in sync tests
  but broke async tests: the Ecto Sandbox's `shared: true` mode
  is repo-wide, so concurrent async tests racing for it got
  `:already_shared`. Moving the load to the calling process
  sidesteps the shared-mode lock entirely — the caller already
  has a connection via the regular pool (or the test's
  sandboxed checkout), and the agent's later `Repo` calls walk
  `$callers` back to that same connection with no per-pid
  `Sandbox.allow/3`.

  ## Agent + message persistence

  `upsert_agent/1` writes (or updates) the `agents` row. The
  Agent's `__append_message__/2` calls `insert_message/2`
  immediately after appending to in-memory state; on
  `__archive_and_compact__/2` it calls `archive_and_compact/4`.
  `load_active_messages/1` is used by the lazy-restore path
  in `Supervisor.get_agent/1`.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.Agent
  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Message
  alias Nest.Repo
  alias Nest.Vocations

  @doc """
  Resolve a `vocation_id` to a loaded `Vocations.Vocation`
  struct (or `nil` if the id is `nil`).

  Returns `nil` (not raising) when the id is non-nil but no
  record exists; matches `Vocations.get_vocation/1`.
  """
  @spec load_vocation(integer() | nil) :: Vocations.Vocation.t() | nil
  def load_vocation(nil), do: nil
  def load_vocation(vocation_id), do: Vocations.get_vocation(vocation_id)

  @doc """
  Build the attrs map the Agent expects, with `:vocation`
  pre-loaded from the DB.

  Pass any other Agent attrs in `attrs` (`id`, `model`,
  `workspace_path`, etc.) — they're merged on top of the
  loaded vocation. `:vocation_id` may be passed by callers
  who don't have the struct handy; this function does the
  fetch and returns the merged map.

  ## Example

      attrs =
        Nest.Persistence.build_agent_attrs(%{
          id: "agent-1",
          model: %{name: "qwen3.5-plus", provider: "model-studio"},
          vocation_id: 42
        })

      Agent.start_link(attrs)
  """
  @spec build_agent_attrs(map()) :: map()
  def build_agent_attrs(attrs) do
    attrs
    |> maybe_load_vocation()
  end

  defp maybe_load_vocation(%{vocation: _vocation} = attrs), do: attrs

  defp maybe_load_vocation(%{vocation_id: id} = attrs) when not is_nil(id) do
    Map.put(attrs, :vocation, load_vocation(id))
  end

  defp maybe_load_vocation(attrs), do: attrs

  @doc """
  Convenience: load the vocation (if any) and start the Agent
  in one call. The caller is responsible for the resulting
  pid (e.g. registering it, supervising it).

  The DB read happens in the calling process; the Agent's
  `init/1` has no DB work. Returns `{:ok, pid}` on success
  (matching `Agent.start_link/1`), or `{:error, reason}` on
  init failure.
  """
  @spec start_agent(map()) :: GenServer.on_start()
  def start_agent(attrs) do
    Agent.start_link(build_agent_attrs(attrs))
  end

  @doc """
  Insert or update the `agents` row for the given attrs.

  `attrs` is the same shape as `build_agent_attrs/1` returns
  (`:id`, `:model`, `:vocation_id`, `:workspace_path`). The
  `next_message_index` is preserved on conflict — restarting
  an existing agent must not lose its in-flight message
  counter. The runtime bumps it via a separate UPDATE
  (`update_next_message_index/2`) when a message is appended.

  Returns `{:ok, %PersistedAgent{}}` on success, or
  `{:error, %Ecto.Changeset{}}` on validation failure.
  """
  @spec upsert_agent(map()) ::
          {:ok, PersistedAgent.t()} | {:error, Ecto.Changeset.t(PersistedAgent.t())}
  def upsert_agent(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # `:next_message_index` is intentionally omitted from
    # `base` and from the `set` list: the runtime owns that
    # counter via `update_next_message_index/2` and bumps it
    # per persisted message. Including it here would (a) reset
    # the counter to whatever `attrs` says on every re-upsert,
    # silently breaking cross-restart recovery, and (b) cause
    # Ecto to return a stale value in the upsert result
    # (because the changeset holds the new value, even though
    # the SET clause leaves the DB column untouched).
    base = %{
      id: Map.fetch!(attrs, :id),
      model: Map.fetch!(attrs, :model),
      vocation_id: Map.get(attrs, :vocation_id),
      workspace_path: Map.get(attrs, :workspace_path),
      next_message_index: Map.get(attrs, :next_message_index, 0),
      inserted_at: now,
      updated_at: now
    }

    insert_opts = [
      on_conflict: [
        set: [
          model: base.model,
          vocation_id: base.vocation_id,
          workspace_path: base.workspace_path,
          updated_at: now
        ]
      ],
      conflict_target: :id
    ]

    case Repo.insert(%PersistedAgent{} |> PersistedAgent.changeset(base), insert_opts) do
      {:ok, _row} ->
        # Reload to get the real `next_message_index` (the
        # upsert's RETURNING only reflects changeset values).
        {:ok, Repo.get!(PersistedAgent, base.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Persist a runtime message into the `messages` table.

  `agent_id` is the owning agent's string id. `message` is
  the canonical `Message.t()` tagged tuple (`:system`,
  `:user`, `:assistant`, `:tool`, `:compaction`). The
  message's `index` field is read off the inner struct and
  used for `message_index` (the caller has already stamped
  it; see `Agent.__append_message__/2`).

  Returns `{:ok, %PersistedMessage{}}` on success, or
  `{:error, term()}` on failure.
  """
  @spec insert_message(String.t(), Message.t()) ::
          {:ok, PersistedMessage.t()} | {:error, term()}
  def insert_message(agent_id, message) do
    attrs = PersistedMessage.from_runtime(agent_id, message)

    %PersistedMessage{}
    |> PersistedMessage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Mark the messages in `[first_index..last_index]` as
  archived, then insert the compaction marker at
  `last_index + 1`, all in one transaction.

  The caller is `Agent.__archive_and_compact__/2`; it
  computes `first_index` and `last_index` from the agent's
  in-memory `state.chat_state.messages` and the
  compactor-produced `new_messages`. The marker is
  rendered as a `role: "compaction"` row with
  `compaction_archived_count` and `compaction_occurred_at`
  populated.

  Returns the new compaction row on success, or
  `{:error, term()}` on failure.
  """
  @spec archive_and_compact(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, PersistedMessage.t()} | {:error, term()}
  def archive_and_compact(agent_id, first_index, last_index, archived_count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    marker_index = last_index + 1

    Repo.transaction(fn ->
      from(m in PersistedMessage,
        where:
          m.agent_id == ^agent_id and m.message_index >= ^first_index and
            m.message_index <= ^last_index
      )
      |> Repo.update_all(set: [archived_at: now])

      %PersistedMessage{}
      |> PersistedMessage.changeset(%{
        agent_id: agent_id,
        message_index: marker_index,
        role: "compaction",
        content: %{"parts" => []},
        inserted_at: now,
        compaction_archived_count: archived_count,
        compaction_occurred_at: now
      })
      |> Repo.insert()
    end)
    |> case do
      {:ok, {:ok, row}} -> {:ok, row}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Bump the `next_message_index` column on the agent row.

  Called after every successful `insert_message/2` so a
  restarted agent reads the right counter on the next
  message append. One UPDATE per message; a single agent's
  counter is in a single row, so this is O(1) and not a
  contention hot spot.
  """
  @spec update_next_message_index(String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def update_next_message_index(agent_id, new_index) do
    from(a in PersistedAgent, where: a.id == ^agent_id)
    |> Repo.update_all(
      set: [
        next_message_index: new_index,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )

    :ok
  end

  @doc """
  Load the active (non-archived) messages for an agent, in
  `message_index` order. Returns a list of `Message.t()`
  tagged tuples (the canonical runtime shape).

  Used by the lazy-restore path in `Supervisor.get_agent/1`.
  The caller is responsible for converting the list into
  the agent's `state.chat_state.messages` and stamping the
  `next_message_index` from the agent row.
  """
  @spec load_active_messages(String.t()) :: [Message.t()]
  def load_active_messages(agent_id) do
    from(m in PersistedMessage,
      where: m.agent_id == ^agent_id and is_nil(m.archived_at),
      order_by: [asc: m.message_index]
    )
    |> Repo.all()
    |> Enum.map(&PersistedMessage.to_runtime/1)
  end

  @doc """
  Load the agent row by id. Returns `nil` when the id has
  never been persisted (e.g. a brand-new agent that's never
  been started) and `{:error, term()}` on DB failure.
  """
  @spec load_agent(String.t()) :: PersistedAgent.t() | nil | {:error, term()}
  def load_agent(agent_id) do
    case Repo.get(PersistedAgent, agent_id) do
      nil -> nil
      %PersistedAgent{} = agent -> agent
    end
  end

  @doc """
  Convenience: load the agent row, the active messages, and
  the vocation struct (if any). Returns `{:ok, attrs_map}`
  suitable for passing to `Agent.start_link/1`, or
  `{:error, :not_found}` when no row exists for the id.

  `attrs_map` mirrors `build_agent_attrs/1`'s output: it
  carries the loaded `Vocation` struct on `:vocation`, the
  `model` from the row, the `workspace_path` from the row,
  the `next_message_index` from the row, and a
  `:preloaded_messages` list of `Message.t()` tuples the
  Agent's `init/1` should seed into `state.chat_state.messages`.

  Used by `Supervisor.get_agent/1`'s lazy-restore path.
  """
  @spec restore_agent(String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def restore_agent(agent_id) do
    case load_agent(agent_id) do
      nil ->
        {:error, :not_found}

      %PersistedAgent{} = row ->
        attrs = %{
          id: row.id,
          model: row.model,
          workspace_path: row.workspace_path,
          next_message_index: row.next_message_index,
          preloaded_messages: load_active_messages(agent_id),
          vocation: load_vocation(row.vocation_id)
        }

        {:ok, attrs}
    end
  end
end
