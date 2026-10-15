defmodule Nest.Agents.Agent.History.Target do
  @moduledoc """
  The agent a history read targets — the resolution `agents-history` and
  `agents-status` share.

  Three rules, the first two of which are the security boundary:

    * No `name` (or an explicitly empty one) means the caller itself
      (`ctx.agent_name`).
    * A name is resolved against the caller's own `space_id` through
      `Nest.Persistence.fetch_agent/2`, which is space-scoped by construction.
      A name that exists only in another space is therefore "not found in this
      space" — the same refusal `agents-query` and `agents-send` give — so a
      tool can never read another space's agent.
    * An *archived* agent is refused. Archiving means "out of service":
      `agents-archive` documents an archived agent as no longer listed or
      queryable. The refusal names the state and what to do about it rather
      than reporting a retired agent's numbers as if it were in service.

  A `name` that is *present but not a string* is a fourth case, and it is a
  refusal rather than a default: `{"name": 123}` is a model typo, and quietly
  reading the caller's own history in its place would answer a question the
  model did not ask. The error names the argument (the shape
  `Nest.Tools.ShellPipes` uses) and says how to mean "myself".

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
    with {:ok, name} <- target_name(ctx, tc) do
      fetch(ctx.space_id, name)
    end
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
  # descriptions promise. Anything else present is either a name or a typo.
  defp target_name(ctx, %ToolCall{arguments: args}) do
    case string_arg(args, "name") do
      :absent -> self_name(ctx)
      {:ok, ""} -> self_name(ctx)
      {:ok, name} -> {:ok, name}
      {:error, _reason} = error -> error
    end
  end

  defp self_name(ctx) do
    case Map.get(ctx, :agent_name) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _other -> {:error, "Missing required argument: name (and this call has no calling agent)."}
    end
  end

  # `:absent` and `{:ok, value}` keep "not given" apart from "given as
  # something unusable", which is the distinction the default turns on.
  defp string_arg(args, key) when is_map(args) do
    case Map.fetch(args, key) do
      :error ->
        :absent

      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, other} ->
        {:error,
         "Invalid `#{key}` argument: expected a string, got: #{inspect(other)}. " <>
           "Omit it to target yourself."}
    end
  end

  defp string_arg(_args, _key), do: :absent
end
