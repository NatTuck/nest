defmodule Nest.Persistence.MessageRepair do
  @moduledoc """
  Offline repair of persisted message sequences
  (`mix nest.repair_messages`).

  Loads every agent in a target scope (a whole space by name, or
  every space), asks `Nest.Persistence.MessageRepair.Planner` for a
  plan, optionally applies it via
  `Nest.Persistence.MessageRepair.Writer`, and formats a report.

  This is the only code path allowed to rewrite persisted
  `messages` rows (see `notes/enforce-mesages-seq-invariants.md`).
  Live agents hold stale in-memory sequences after a repair, so an
  operator must restart the affected agents.
  """

  alias Nest.Agents.PersistedAgent
  alias Nest.LLM.Preflight
  alias Nest.Persistence
  alias Nest.Persistence.MessageRepair.Planner
  alias Nest.Persistence.MessageRepair.Writer
  alias Nest.Persistence.Messages, as: PersistenceMessages
  alias Nest.Spaces

  @type target :: {:space, String.t()} | :all

  @doc """
  Load the target scope, plan repairs, and (when `apply?: true`)
  write them.

  Returns `{:ok, plan, agents_by_id}` or `{:error, reason}`.
  """
  @spec run(target(), keyword()) ::
          {:ok, Planner.t(), %{integer() => PersistedAgent.t()}} | {:error, term()}
  def run(target, opts \\ []) do
    with {:ok, agents} <- load_agents(target) do
      rows = PersistenceMessages.load_rows_by_agent(Enum.map(agents, & &1.id))
      plan = Planner.plan(agents, rows)
      agents_by_id = Map.new(agents, &{&1.id, &1})

      case maybe_apply(plan, opts) do
        :ok -> {:ok, plan, agents_by_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_apply(plan, opts) do
    if Keyword.get(opts, :apply, false), do: Writer.apply(plan), else: :ok
  end

  defp load_agents({:space, name}) do
    case Spaces.get_by_name(name) do
      nil -> {:error, {:space_not_found, name}}
      %{id: id} -> {:ok, Persistence.fetch_all_agents_for_space(id)}
    end
  end

  defp load_agents(:all), do: {:ok, Persistence.list_all_agents()}

  @doc """
  True when any targeted agent's sequence still violates the wire
  rules after planning.
  """
  @spec residual?(Planner.t()) :: boolean()
  def residual?(%Planner{} = plan), do: map_size(plan.residual_violations) > 0

  @doc """
  True when any targeted agent's original sequence violated the
  wire rules.
  """
  @spec violations?(Planner.t()) :: boolean()
  def violations?(%Planner{} = plan), do: map_size(plan.original_violations) > 0

  @doc """
  Render a human-readable report of a plan. `verbose` adds the exact
  inserts and renumbering per agent.
  """
  @spec format_report(Planner.t(), %{integer() => PersistedAgent.t()}, boolean()) :: String.t()
  def format_report(%Planner{} = plan, agents, verbose \\ false) do
    [
      summary(plan, agents),
      violations_section("Violations found", plan.original_violations, agents),
      if(verbose, do: plan_section(plan, agents), else: ""),
      violations_section("Residual violations", plan.residual_violations, agents)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp summary(plan, agents) do
    "Repair plan: #{length(plan.inserts)} insert(s), #{length(plan.rewrites)} rewrite(s), " <>
      "#{map_size(plan.original_violations)} agent(s) with violations across " <>
      "#{map_size(agents)} agent(s)."
  end

  defp violations_section(_title, violations, _agents) when map_size(violations) == 0, do: ""

  defp violations_section(title, violations, agents) do
    lines =
      violations
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.flat_map(fn {id, agent_violations} ->
        [agent_label(id, agents), "  " <> Preflight.format_violations(agent_violations)]
      end)

    Enum.join([title | lines], "\n")
  end

  defp plan_section(plan, agents) do
    inserts = plan.inserts |> Enum.group_by(& &1.agent_id) |> insert_lines(agents)

    updates =
      plan.agent_updates |> Map.keys() |> Enum.sort() |> Enum.map(&update_line(&1, agents))

    Enum.join(["Planned writes" | inserts ++ updates], "\n")
  end

  defp insert_lines(grouped, agents) do
    grouped
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.flat_map(fn {id, rows} ->
      [agent_label(id, agents) <> " inserts at #{inspect(Enum.map(rows, & &1.index))}"]
    end)
  end

  defp update_line(id, agents) do
    agent_label(id, agents) <> " counters updated"
  end

  defp agent_label(id, agents) do
    case agents[id] do
      %PersistedAgent{name: name, space_id: space_id} ->
        "  agent #{name} (id=#{id}, space=#{space_id})"

      _ ->
        "  agent id=#{id}"
    end
  end
end
