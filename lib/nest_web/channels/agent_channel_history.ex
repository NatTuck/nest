defmodule NestWeb.AgentChannel.History do
  @moduledoc """
  A page of the agent's archived (pre-compaction) history for the
  agent channel's `chat:history` reply.

  The archive is never part of the join payload: for a long-lived agent
  it is the whole summarized prefix — thousands of rows and megabytes of
  tool output. The client asks for the rows it is about to render (the
  collapsed-history card pages through them) and for the two small
  projections it needs up front (the latest compaction marker, and the
  user prompts behind the Ctrl/Cmd+Up recall list).

  The read is a plain DB query — the archive lives in the DB, never in
  agent state — so resolving it cannot block a live turn. Extracted from
  `NestWeb.AgentChannel` so that module stays within the file-length
  budget.
  """

  alias Nest.Messages.Message
  alias Nest.Persistence

  # The archive holds thousands of rows for a long-lived agent, so it is
  # only ever read a page at a time; the ceiling keeps a misbehaving
  # client from asking for the lot.
  @default_limit 50
  @max_limit 200
  @roles ~w(system user assistant tool compaction)

  @doc """
  One page of the agent's history, as the `chat:history` reply payload.

  `payload` carries the client's `before` cursor, `limit`, and `role`
  projection filter. Returns `{:ok, %{"messages" => [...]}}`, or
  `{:error, reason}` with the wire reason string for a malformed
  payload.
  """
  @spec page(integer(), String.t(), map()) ::
          {:ok, %{required(String.t()) => [map()]}} | {:error, String.t()}
  def page(space_id, name, payload) do
    with {:ok, opts} <- opts(payload) do
      rows = Persistence.load_history_slice(space_id, name, opts)
      {:ok, %{"messages" => Enum.map(rows, &Message.to_json/1)}}
    end
  end

  # `before` walks backwards through the archive (`nil` starts at the
  # boundary), `limit` bounds one page, and `role` selects a
  # projection — the recall list wants only `user` rows, the card wants
  # every role.
  defp opts(payload) do
    with {:ok, before} <- parse_before(payload["before"]),
         {:ok, limit} <- parse_limit(payload["limit"]),
         {:ok, roles} <- parse_role(payload["role"]) do
      {:ok, [before: before, limit: limit, roles: roles, origin: recall_origin(roles)]}
    end
  end

  # The `role: "user"` projection *is* the Ctrl/Cmd+Up recall list — its only
  # production consumer — so the page is filtered to the human's own prompts
  # here, not just on the client: delivered peer messages and notices are
  # user-role rows carrying no `origin` marker, and they must not eat the page
  # budget. The rule is implicit in the projection on purpose, so a client
  # cannot forget it and silently get deliveries back; a caller that wants every
  # user row asks for no role and filters client-side.
  defp recall_origin(["user"]), do: "human"
  defp recall_origin(_roles), do: nil

  defp parse_before(nil), do: {:ok, nil}
  defp parse_before(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp parse_before(_other), do: {:error, "invalid_before"}

  defp parse_limit(nil), do: {:ok, @default_limit}

  defp parse_limit(n) when is_integer(n) and n > 0,
    do: {:ok, min(n, @max_limit)}

  defp parse_limit(_other), do: {:error, "invalid_limit"}

  defp parse_role(nil), do: {:ok, nil}
  defp parse_role(role) when role in @roles, do: {:ok, [role]}
  defp parse_role(_other), do: {:error, "invalid_role"}
end
