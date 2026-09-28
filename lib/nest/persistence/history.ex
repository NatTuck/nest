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
  `fork_message_index`, because `Messages.load_full_messages/2` resolves the
  shared prefix first.
  """

  alias Nest.Messages.Message
  alias Nest.Persistence.Messages

  @doc """
  Rows of `agent_name`'s logical sequence at or below its compaction
  boundary, in index order. `[]` for an agent that has never compacted
  (boundary `-1`) or does not exist.
  """
  @spec load(integer(), String.t()) :: [Message.t()]
  def load(space_id, agent_name) do
    case Messages.last_compaction_index(space_id, agent_name) do
      {:ok, boundary} ->
        space_id
        |> Messages.load_full_messages(agent_name)
        |> Enum.filter(fn {_role, %{index: idx}} -> idx <= boundary end)

      {:error, _reason} ->
        []
    end
  end
end
