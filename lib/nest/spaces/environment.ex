defmodule Nest.Spaces.Environment do
  @moduledoc """
  The space edit's **two phases**: the plan, the latch, and the cancellation.

  `Nest.Spaces` owns the row and the announcement (`write_environment/3`); this
  owns everything about *when* that write is allowed to happen, because an edit
  stops work and the user has to be told what it costs first.

  ## Two phases

  The first call answers `{:error, {:confirmation_required, plan}}` when anything
  in the space is running, and the plan names it. The second — the same call with
  `confirm: true` — does the edit. Nothing is written in between.

  ## The latch

  `Nest.Agents.SpaceGate` is held from *before* the plan is read until the edit
  finishes, and it stays up while the user decides. That is what makes the plan
  exact — nothing can start in the space, so the set it names cannot grow — and
  what makes cancelling free: the latch comes down and everything proceeds. A
  client that says no releases it (`NestWeb.LobbyChannel`'s `cancel_edit_space`);
  so does the channel dying, and so does the claim's TTL.

  ## What "stops work" means

  A tool call in flight is **cancelled** — its worker stops the command and
  reports a tool error, so the agent sees why the call did not run and can
  re-issue it. The turn is not stopped: no partial is finalized and no reply is
  given up. A background shell job is stopped, because it may be running in the
  container that is about to be released.

  The statuses that count are the ones with work in flight
  (`@working_statuses`). A *blocked* agent (`Nest.Agents.Agent.Machine`'s
  `blocked_phases/0`) has nothing running, ignores both a stop and a notice, and
  is told by the start path instead.
  """

  alias Nest.Agents
  alias Nest.Agents.SpaceGate
  alias Nest.Sandbox.ShellJobs
  alias Nest.Spaces
  alias Nest.Spaces.Space

  @typedoc """
  What an environment edit would stop, as the confirmation dialog shows it.

  `:agents` are the live agents that are *working* (streaming, running tools or
  compacting) — the ones the edit cancels; `:jobs` is the space's running
  background shell jobs, which are stopped whether or not their agent is busy.
  """
  @type edit_plan :: %{
          agents: [%{name: String.t(), status: atom(), jobs: non_neg_integer()}],
          jobs: non_neg_integer()
        }

  @working_statuses [:streaming, :executing_tools, :compacting]

  # What a cancelled tool call reports to the agent. It names the change rather
  # than saying "cancelled", so the agent can see why the call did not run and
  # decide whether to re-issue it.
  @environment_changed "The space's environment changed; this call did not run. " <>
                         "Re-issue it if you still need it."

  # Documented on `Nest.Spaces.update_environment/3`, the context's entry point.
  @doc false
  @spec update_environment(integer(), map(), keyword()) ::
          {:ok, Space.t()}
          | {:error,
             Ecto.Changeset.t()
             | :not_found
             | :space_changing
             | :workspace_missing
             | :workspace_under_tmp
             | {:config_file_not_regular, String.t(), atom()}
             | {:confirmation_required, edit_plan()}}
  def update_environment(id, params, opts \\ []) when is_integer(id) and is_map(params) do
    case Spaces.get_space(id) do
      nil ->
        {:error, :not_found}

      %Space{sandbox_backend: old_backend} = space ->
        decide(space, params, old_backend, opts)
    end
  end

  defp decide(space, params, old_backend, opts) do
    with :ok <- hold(space.id) do
      plan = edit_plan(space.id)

      if Keyword.get(opts, :confirm, false) or quiet?(plan) do
        edit(space, params, old_backend, plan)
      else
        # The latch stays up while the user decides: nothing can start in the
        # space, so the plan the dialog shows cannot go stale, and cancelling
        # costs nothing but the pause.
        {:error, {:confirmation_required, plan}}
      end
    end
  end

  # The latch comes down whatever the write did: a refused changeset, a workspace
  # the sandbox will not take, or a successful edit.
  defp edit(space, params, old_backend, plan) do
    quiesce(space.id, plan)
    Spaces.write_environment(space, params, old_backend)
  after
    SpaceGate.release(space.id)
  end

  defp hold(id) do
    case SpaceGate.hold(id, :space_edit) do
      :ok -> :ok
      {:error, :already_held} -> {:error, :space_changing}
    end
  end

  defp quiet?(%{agents: [], jobs: 0}), do: true
  defp quiet?(_plan), do: false

  # What the edit would stop, read once while the latch is up. A stopped agent has
  # no process and no work, so it is not in `live_agents/1` at all.
  defp edit_plan(id) do
    live = live_agents(id)
    jobs = Map.new(live, fn {name, _pid} -> {name, running_jobs(id, name)} end)

    agents =
      for {name, pid} <- live,
          status = live_status(pid),
          status in @working_statuses,
          do: %{name: name, status: status, jobs: Map.fetch!(jobs, name)}

    %{agents: agents, jobs: jobs |> Map.values() |> Enum.sum()}
  end

  # The agents of `space_id` with a live process. `get_running_agent/2`, never
  # `get_agent/2`: the latter would *start* a stopped agent, and this edit must not
  # be the thing that brings one up.
  defp live_agents(id) do
    id
    |> Agents.Registry.list_for_space()
    |> Enum.flat_map(fn name ->
      case Agents.Registry.lookup(id, name) do
        {:ok, pid} -> [{name, pid}]
        {:error, :not_found} -> []
      end
    end)
  end

  # A pid that dies between the registry read and this call is not working.
  defp live_status(pid) do
    Agents.Agent.get_public_info(pid, 1_000).status
  catch
    :exit, _ -> :idle
  end

  defp running_jobs(id, name) do
    id
    |> then(&{&1, name})
    |> ShellJobs.list()
    |> Enum.count(&(&1.status == :running))
  end

  # The space's own work cannot survive the change: a tool call in flight would
  # finish against the environment being replaced, and a background job may be
  # running in the container that is about to be released. Both are cancelled
  # here — between the latch going up and the row being written — so nothing can
  # start in the window the cancellation opens.
  defp quiesce(id, plan) do
    Enum.each(plan.agents, fn %{name: name} ->
      case Agents.Registry.lookup(id, name) do
        {:ok, pid} -> Agents.Agent.cancel_tools(pid, @environment_changed)
        {:error, :not_found} -> :ok
      end
    end)

    Enum.each(live_agents(id), fn {name, _pid} -> ShellJobs.stop_jobs({id, name}) end)

    :ok
  end
end
