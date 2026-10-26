defmodule Nest.Spaces.EnvironmentNotice do
  @moduledoc """
  What a space's agents are told when its environment changes, and the flag that
  records it for the agents that cannot be told now.

  `Nest.Spaces.commit_environment/2` writes the row and then calls
  `announce/1`; this module owns everything after the write. Split out of
  `Nest.Spaces` for the source-file cap, and because it is one subject: the two
  halves of "tell everyone, and remember who could not be told".

  The values travel on an agent's `Nest.Sandbox.Mounts`, which is what its caps
  are resolved from and what its tool closures were built with, so an agent that
  started before the change would otherwise keep the old values for the rest of
  its life — this is the only thing that closes that window short of a restart.
  """

  import Ecto.Query, warn: false

  alias Nest.Agents
  alias Nest.Agents.PersistedAgent
  alias Nest.Repo
  alias Nest.Spaces
  alias Nest.Spaces.Space

  @doc """
  Announce `space`'s new environment to every live agent in it, and mark the rest.

  Every agent in the space is owed the notice, and the flag is what records it
  for an agent that cannot be told now.
  """
  @spec announce(Space.t()) :: :ok
  def announce(%Space{id: id} = space) do
    mark_pending(id)
    tell_agents(space)
  end

  # Mark *every* agent first, in one statement, then cast the live ones. A live
  # agent answers the cast by appending the pair and clearing its own flag, so it
  # ends up clear; a stopped agent, and a **mid-turn** one — the cast cannot
  # deliver the notice to a machine that is `:generating` or `:executing_tools`
  # (`Nest.Agents.Agent.WorkspaceHandler`) — keeps the flag and announces the
  # change at its next start.
  #
  # Marking every agent rather than only the ones with no process is what makes
  # the mid-turn case recoverable at all: an agent that is *cast* cannot be
  # excluded from the mark, because the cast is a request it may refuse.
  #
  # ## The one window this does not close
  #
  # The mark and the clear are both plain writes to one boolean, so an edit that
  # lands *inside* an agent's start can still be erased: the start path reads the
  # flag from its attrs snapshot, appends its notice and then writes `false`
  # unconditionally. If edit 1 marked the agent before that snapshot (so the start
  # has a notice to append) and edit 2 marks it after the snapshot but before the
  # clear, edit 2's mark is overwritten — and if edit 2's cast is then refused
  # because the agent is busy, edit 2's notice is lost until a later edit.
  #
  # Closing it needs a compare-and-set, which needs a mark stamp on the row (a
  # migration) — more machinery than a window this narrow justifies: it takes two
  # edits and a start interleaved to the message, and the agent still announces
  # the *first* edit's values. It is recorded here rather than implied away: the
  # duplicate pair below is the harmless half of the trade, this is the half that
  # is a loss.
  #
  # The harmless half: an agent that starts inside the window announces at start
  # and then finds the cast in its mailbox, so it appends the pair twice. The pair
  # reconciles the values now in force, so a duplicate is not misleading.
  defp mark_pending(id) do
    from(a in PersistedAgent, where: a.space_id == ^id)
    |> Repo.update_all(set: [space_notice_pending: true])

    :ok
  end

  # A cast, not a call: the values are the *space's*, so there is nothing an agent
  # could refuse, and an edit must not wait on a turn. A name in the registry with
  # no live process behind it is skipped; that agent's `space_notice_pending` flag
  # is what tells it on its next start.
  defp tell_agents(%Space{id: id} = space) do
    values = Spaces.environment_values(space)

    id
    |> Agents.Registry.list_for_space()
    |> Enum.each(fn name ->
      case Agents.Registry.lookup(id, name) do
        {:ok, pid} -> Agents.Agent.space_changed(pid, values)
        {:error, :not_found} -> :ok
      end
    end)
  end
end
