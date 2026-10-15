defmodule Nest.Agents.Agent.History.Target do
  @moduledoc """
  The agent a history read targets — the resolution `agents-history` and
  `agents-status` share.

  Three rules, the first two of which are the security boundary:

    * No `name` means the caller itself (`ctx.agent_name`).
    * A name is resolved against the caller's own `space_id` through
      `Nest.Persistence.fetch_agent/2`, which is space-scoped by construction.
      A name that exists only in another space is therefore "not found in this
      space" — the same refusal `agents-query` and `agents-send` give — so a
      tool can never read another space's agent.
    * An *archived* agent is refused. Archiving means "out of service":
      `agents-archive` documents an archived agent as no longer listed or
      queryable. The refusal names the state and what to do about it rather
      than reporting a retired agent's numbers as if it were in service.

  The row is returned rather than just the name because both readers need its
  counters: `next_message_index` (the count of messages, and so the index the
  next append will take) and `last_compaction_index`.
  """

  alias Nest.Agents.PersistedAgent
  alias Nest.Messages.ToolCall
  alias Nest.Persistence

  @doc """
  Resolve the call's target to `{name, row}` in `ctx.space_id`, or an error
  result naming why it cannot be read.
  """
  @spec resolve(map(), ToolCall.t()) ::
          {:ok, String.t(), PersistedAgent.t()} | {:error, String.t()}
  def resolve(ctx, %ToolCall{} = tc) do
    fetch(ctx.space_id, name_from(ctx, tc))
  end

  defp fetch(_space_id, name) when not is_binary(name) or name == "" do
    {:error, "Missing required argument: name (and this call has no calling agent)."}
  end

  defp fetch(space_id, name) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, %PersistedAgent{archived: true}} ->
        {:error,
         "Agent #{name} is archived, so it is out of service; " <>
           "restore it with agents-unarchive first."}

      {:ok, row} ->
        {:ok, name, row}

      {:error, :not_found} ->
        {:error, "Agent #{name} not found in this space."}
    end
  end

  # A missing (or empty) `name` is the caller itself, which is what both tools'
  # descriptions say the default is.
  defp name_from(ctx, %ToolCall{arguments: args}) do
    case string_arg(args, "name") do
      "" -> Map.get(ctx, :agent_name, "")
      name -> name
    end
  end

  defp string_arg(args, key) when is_map(args) do
    case Map.get(args, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp string_arg(_args, _key), do: ""
end
