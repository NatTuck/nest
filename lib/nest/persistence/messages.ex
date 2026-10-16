defmodule Nest.Persistence.Messages do
  @moduledoc """
  Message-load and agent-counter helpers extracted from
  `Nest.Persistence` so the parent module stays under the
  credo 500-line cap.

  Owns the per-agent reads (`load_messages/2`,
  `load_full_messages/2`, `last_compaction_index/2`) and the
  `update_next_message_index_by_id/2` /
  `update_fork_message_index/3` counter bumps. All functions
  take `space_id` as the first argument since agent names are
  unique within a space — except the counter bump, which is
  keyed by `agents.id` so a name that has been taken over
  cannot redirect it.

  `load_messages/2` returns only the rows the agent *owns*.
  `load_full_messages/2` returns the agent's full logical
  sequence by recursively resolving the shared prefix through
  `parent_id` (see `notes/shared-message-structure.md`).
  """

  import Ecto.Query, warn: false

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Message
  alias Nest.Repo

  @spec load_messages(integer(), String.t()) :: [Message.t()]
  def load_messages(space_id, agent_name) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, %PersistedAgent{id: agent_id}} -> load_own_messages(agent_id)
      {:error, :not_found} -> []
    end
  end

  @doc """
  Load an agent's full logical sequence: its own rows plus the
  ancestor rows it shares below its `fork_message_index`,
  resolved recursively via `parent_id`.

  A root or fresh child (`fork_message_index` is `nil`) resolves
  to its own rows. A clone resolves to
  `before(full(parent), fork) ++ own`, where `before/2` keeps
  rows with a lower `message_index`.

  Unbounded form of `load_slice/3`; prefer the slice when the
  caller only needs a page.
  """
  @spec load_full_messages(integer(), String.t()) :: [Message.t()]
  def load_full_messages(space_id, agent_name) do
    load_slice(space_id, agent_name, cap: :all, limit: :all)
  end

  @doc """
  Load a bounded slice of an agent's logical sequence: the most
  recent `:limit` rows with `message_index <= :cap`, optionally
  restricted to `:roles`.

  Walks the same shared-prefix chain as `load_full_messages/2`,
  but caps each ancestor's own rows at the child's fork and pushes
  a `LIMIT` into the query, so the cost is O(limit) per ancestor
  instead of O(whole sequence). Every row of an ancestor's
  sequence sits below the child's fork, so capping the whole
  subtree at `fork - 1` keeps exactly the inherited rows.

  `:cap` and `:limit` accept `:all` for "no bound". Rows come back
  in ascending `message_index` order.
  """
  @spec load_slice(integer(), String.t(), keyword()) :: [Message.t()]
  def load_slice(space_id, agent_name, opts) do
    load(space_id, agent_name, Keyword.delete(opts, :decode))
  end

  # The one entry point both public readers go through. `:decode` is internal
  # — `load_slice/3` strips it so only `archived_summary/3` can ask for
  # undecoded rows, and it defaults to decoding when absent.
  defp load(space_id, agent_name, opts) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, row} -> collect_slice(row, MapSet.new(), opts)
      {:error, :not_found} -> []
    end
  end

  @doc """
  Summarize the rows at or below `boundary` without reading their payloads.

  The load path needs exactly three facts about the archived prefix — whether
  a system row exists anywhere in the logical sequence, the highest index the
  archive reaches, and how many compaction markers sit at or below the
  boundary — and nothing at all about their content. Reading them as full
  messages decodes every archived row's JSON, which is what made a cold start
  scale with the whole conversation instead of the active window (issue #52).

  This reads the same rows through the same shared-prefix walk, as a
  projection, so the facts are identical to the ones a full read would give
  and only the decode is skipped. A clone's inherited prefix is included,
  which is what makes the marker count right for a clone whose boundary is
  one it inherited from its parent.

  A `boundary` below zero means nothing is archived.
  """
  @spec archived_summary(integer(), String.t(), integer()) :: %{
          has_system_row: boolean(),
          highest_index: integer(),
          marker_count: non_neg_integer()
        }
  def archived_summary(_space_id, _agent_name, boundary) when boundary < 0 do
    %{has_system_row: false, highest_index: -1, marker_count: 0}
  end

  def archived_summary(space_id, agent_name, boundary) do
    rows =
      load(space_id, agent_name,
        cap: boundary,
        limit: :all,
        decode: false,
        select: [:message_index, :role, :compaction_count]
      )

    %{
      has_system_row: Enum.any?(rows, &(&1.role == "system")),
      highest_index: rows |> Enum.map(& &1.message_index) |> Enum.max(fn -> -1 end),
      marker_count: Enum.count(rows, &(&1.role == "compaction"))
    }
  end

  defp collect_slice(%PersistedAgent{} = row, seen, opts) do
    cap = Keyword.fetch!(opts, :cap)
    limit = Keyword.get(opts, :limit, :all)
    roles = Keyword.get(opts, :roles)
    origin = Keyword.get(opts, :origin)
    floor = Keyword.get(opts, :floor)

    own = load_own_slice(row, cap, limit, roles, origin, floor, opts)
    remaining = subtract_limit(limit, length(own))

    case shared_parent(row, seen) do
      {:ok, parent, fork} when remaining != 0 ->
        parent_cap = min_cap(cap, fork - 1)

        if parent_cap == :none do
          own
        else
          parent_opts =
            opts
            |> Keyword.put(:cap, parent_cap)
            |> Keyword.put(:limit, remaining)

          collect_slice(parent, MapSet.put(seen, row.id), parent_opts) ++ own
        end

      _ ->
        own
    end
  end

  defp load_own_slice(row, cap, limit, roles, origin, floor, opts) do
    PersistedMessage
    |> where([m], m.agent_id == ^row.id)
    |> floor_index(floor)
    |> cap_index(cap)
    |> filter_roles(roles)
    |> filter_origin(origin)
    |> select_projection(Keyword.get(opts, :select))
    |> order_by([m], desc: m.message_index)
    |> cap_rows(limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&decode_row(&1, opts))
  end

  # `:floor` is the exclusive lower bound: rows *above* it. It is the
  # counterpart of `:cap`, and the two partition a sequence between them —
  # `cap: b` plus `floor: b` is every row, exactly once.
  defp floor_index(query, nil), do: query
  defp floor_index(query, floor), do: where(query, [m], m.message_index > ^floor)

  # A projection read skips `to_runtime/1` entirely, so an archived row never
  # pays for decoding a payload nobody will look at.
  defp select_projection(query, nil), do: query
  defp select_projection(query, fields), do: select(query, ^fields)

  defp decode_row(row, opts) do
    if Keyword.get(opts, :decode, true) do
      PersistedMessage.to_runtime(row)
    else
      row
    end
  end

  # `:all` bounds are dropped from the query entirely rather than
  # turned into a sentinel value, so the unbounded form stays a
  # plain index scan.
  defp cap_index(query, :all), do: query
  defp cap_index(query, cap), do: where(query, [m], m.message_index <= ^cap)

  defp filter_roles(query, nil), do: query
  defp filter_roles(query, roles), do: where(query, [m], m.role in ^roles)

  # Restrict to rows carrying a given `metadata["origin"]` value. The recall
  # projection asks for `"human"` so that delivered peer messages and notices
  # (user-role rows with no marker) do not eat the page budget. A NULL
  # `metadata` — or a row without the key — never equals the value, so this is
  # fail-closed, exactly like the client-side filter it mirrors.
  defp filter_origin(query, nil), do: query

  defp filter_origin(query, origin),
    do: where(query, [m], fragment("? ->> 'origin' = ?", m.metadata, ^origin))

  defp cap_rows(query, :all), do: query
  defp cap_rows(query, limit), do: limit(query, ^limit)

  defp subtract_limit(:all, _own), do: :all
  defp subtract_limit(limit, own), do: limit - own

  # A fork of 0 means the clone shares nothing, so the ancestor
  # contributes no rows at all.
  defp min_cap(_cap, -1), do: :none
  defp min_cap(:all, cap), do: cap
  defp min_cap(cap, fork_cap), do: min(cap, fork_cap)

  @spec load_own_messages(integer()) :: [Message.t()]
  def load_own_messages(agent_id) when is_integer(agent_id) do
    from(m in PersistedMessage,
      where: m.agent_id == ^agent_id,
      order_by: [asc: m.message_index]
    )
    |> Repo.all()
    |> Enum.map(&PersistedMessage.to_runtime/1)
  end

  @doc """
  Bulk-load the *schema* rows for a set of agents, grouped by
  `agent_id` and ordered by `message_index`. Unlike
  `load_own_messages/1`, this keeps the `%PersistedMessage{}`
  rows (with their primary keys) so the offline repair tool can
  renumber and rewrite them.
  """
  @spec load_rows_by_agent([integer()]) :: %{integer() => [PersistedMessage.t()]}
  def load_rows_by_agent(agent_ids) when is_list(agent_ids) do
    from(m in PersistedMessage,
      where: m.agent_id in ^agent_ids,
      order_by: [asc: m.agent_id, asc: m.message_index]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.agent_id)
  end

  # The parent to inherit a shared prefix from, or `:none` for a
  # root, a fresh child, a cycle, or a missing
  # parent row.
  defp shared_parent(%PersistedAgent{parent_id: parent_id, fork_message_index: fork}, seen)
       when is_integer(parent_id) and is_integer(fork) do
    if MapSet.member?(seen, parent_id) do
      :none
    else
      case fetch_agent_by_id(parent_id) do
        {:ok, parent} -> {:ok, parent, fork}
        {:error, :not_found} -> :none
      end
    end
  end

  defp shared_parent(_row, _seen), do: :none

  @spec fetch_agent_by_id(integer()) :: {:ok, PersistedAgent.t()} | {:error, :not_found}
  defp fetch_agent_by_id(id) do
    case Repo.get(PersistedAgent, id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @spec last_compaction_index(integer(), String.t()) ::
          {:ok, integer()} | {:error, :agent_not_found}
  def last_compaction_index(space_id, agent_name) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, %PersistedAgent{last_compaction_index: idx}} -> {:ok, idx}
      {:error, :not_found} -> {:error, :agent_not_found}
    end
  end

  @doc """
  Bump the `next_message_index` column on the agent row with this
  `agents.id`.

  Keyed by id, not by name: the append path calls this with the
  `agent_id` of the row its INSERT just returned, so a name taken over
  between the two writes can never move a *successor's* counter. An id
  that no longer exists is a no-op — the message row cascaded away with
  it, so there is nothing left to keep in step.
  """
  @spec update_next_message_index_by_id(integer(), non_neg_integer()) :: :ok
  def update_next_message_index_by_id(agent_id, new_index) when is_integer(agent_id) do
    now = Nest.Persistence.now()

    from(a in PersistedAgent, where: a.id == ^agent_id)
    |> Repo.update_all(
      set: [
        next_message_index: new_index,
        updated_at: now
      ]
    )

    :ok
  end

  @doc """
  Set (or clear, with `nil`) an agent's fork boundary. Clearing is
  only meaningful for repair: the live path never clears it, since a
  clone keeps its fork pointer for life (see
  `notes/shared-message-structure.md`).
  """
  @spec update_fork_message_index(integer(), String.t(), non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def update_fork_message_index(space_id, agent_name, fork_message_index)
      when is_integer(fork_message_index) or is_nil(fork_message_index) do
    case Nest.Persistence.fetch_agent(space_id, agent_name) do
      {:ok, %PersistedAgent{id: agent_id}} ->
        now = Nest.Persistence.now()

        from(a in PersistedAgent, where: a.id == ^agent_id)
        |> Repo.update_all(
          set: [
            fork_message_index: fork_message_index,
            updated_at: now
          ]
        )

        :ok

      {:error, :not_found} ->
        {:error, :agent_not_found}
    end
  end
end
