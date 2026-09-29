defmodule Nest.Persistence.History do
  @moduledoc """
  The archived slice of an agent message sequence, resolved on demand.

  `history` is the rows with `message_index <= agents.last_compaction_index`,
  which includes the `{:compaction, _}` marker itself (the `<=` rule).

  It is a *derived view*: never held in agent state, and display/audit only.
  The LLM-facing context is the agent's in-memory `chat_state.messages`; no
  payload builder may read this module's output. Keeping the two apart is what
  keeps a non-LLM-visible marker row (and the summarized-away prefix) out of a
  request.

  A clone's archived slice includes the ancestor rows it shares below its
  `fork_message_index`, because `Messages.load_slice/3` resolves the shared
  prefix first.

  The archive is never shipped whole: for a long-lived agent it holds the
  entire summarized prefix (thousands of rows, megabytes of tool output). The
  join payload carries only the boundary numbers, and callers page through
  `load_slice/3` for the rows they actually render.
  """

  alias Nest.Messages.Message
  alias Nest.Persistence.Messages

  # Rows per page when the caller doesn't ask for a size. Small
  # enough that a page is a cheap frame, large enough that the
  # collapsed-history card fills a screen in one round trip.
  @default_limit 50

  @doc """
  Rows of `agent_name`'s logical sequence at or below its compaction
  boundary, in index order. `[]` for an agent that has never compacted
  (boundary `-1`) or does not exist.

  Unbounded — prefer `load_slice/3` for anything the UI renders.
  """
  @spec load(integer(), String.t()) :: [Message.t()]
  def load(space_id, agent_name) do
    load_slice(space_id, agent_name, limit: :all)
  end

  @doc """
  One page of the archive: the most recent `:limit` rows at or below the
  compaction boundary, restricted to rows before `:before` (exclusive)
  and to `:roles` when given.

  Returns rows in ascending index order, so the page's first row is the
  oldest one in it and a follow-up call pages further back with
  `before: first_index`. `[]` once the caller has walked past index 0.
  """
  @spec load_slice(integer(), String.t(), keyword()) :: [Message.t()]
  def load_slice(space_id, agent_name, opts) do
    limit = Keyword.get(opts, :limit) || @default_limit
    before = Keyword.get(opts, :before)

    case Messages.last_compaction_index(space_id, agent_name) do
      {:ok, boundary} when boundary >= 0 ->
        Messages.load_slice(space_id, agent_name,
          cap: cap(boundary, before),
          limit: limit,
          roles: Keyword.get(opts, :roles)
        )

      _ ->
        []
    end
  end

  # The boundary is the highest archived index, so `before: nil` starts
  # at the end of the archive and `before: first_index` walks back.
  defp cap(boundary, nil), do: boundary
  defp cap(boundary, before), do: min(boundary, before - 1)
end
