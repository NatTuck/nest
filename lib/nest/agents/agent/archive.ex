defmodule Nest.Agents.Agent.Archive do
  @moduledoc """
  Execution of the `agents-archive` tool.

  Split out of `Nest.Agents.Agent.ToolLoop`, which is at its file-length cap,
  for the same reason `Nest.Agents.Agent.WaitForIdle` is separate: the tool's
  spec lives in `Nest.Tools`, and the work it drives lives beside the agent
  that runs it.

  `name` takes one agent name or a list of them, because cleaning up after a
  multi-agent workflow usually means several at once. Each name is archived
  with its own call to the parent agent, so one refusal does not abandon the
  names after it, and the content names every outcome.
  """

  alias Nest.Agents.Registry, as: AgentsRegistry
  alias Nest.Messages.ToolCall

  @doc """
  Archive every agent the call names, as `{content, is_error}`.

  `is_error` is true when any name failed — the call did not fully succeed —
  and the content still reports the names that did, so a partial archive is
  visible rather than silent.
  """
  @spec run(map(), ToolCall.t()) :: {String.t(), boolean()}
  def run(ctx, %ToolCall{} = tc) do
    case archive_names(tc.arguments) do
      {:ok, names} ->
        parent = AgentsRegistry.via_tuple(ctx.space_id, ctx.agent_name)
        results = Enum.map(names, &archive_one(parent, &1))
        content = Enum.map_join(results, "\n", &sentence/1)
        failed = Enum.any?(results, &match?({:error, _}, &1))

        {content, failed}

      {:error, message} ->
        {message, true}
    end
  end

  # One parent call per name: `Supervisor.archive_agent/2` already archives a
  # whole subtree, so a name is the right granularity, and doing them one at a
  # time keeps one refusal from abandoning the names after it.
  defp archive_one(parent, name) do
    case GenServer.call(parent, {:archive_agent_request, self(), name}) do
      {:ok, archived} -> {:ok, archived}
      {:error, reason} -> {:error, {name, reason}}
    end
  end

  # The single-name forms are byte-identical to what this tool produced before
  # it accepted a list, so nothing that read them has to change.
  defp sentence({:ok, archived}), do: "Archived agent #{archived}."
  defp sentence({:error, {name, reason}}), do: "Could not archive #{name}: #{inspect(reason)}"

  # `name` takes one agent name or a list of them. A non-string, a list with a
  # non-string element, and an empty list are all rejected loudly rather than
  # filtered: silently dropping a name would leave an agent the caller asked to
  # clean up running, and an empty list is far more likely to be a malformed
  # call than a request to archive nothing.
  defp archive_names(args) when is_map(args), do: names_from(Map.get(args, "name"))
  defp archive_names(_args), do: {:error, names_error(nil)}

  defp names_from(name) when is_binary(name) and name != "", do: {:ok, [name]}

  defp names_from(names) when is_list(names) do
    if valid_names?(names), do: {:ok, names}, else: {:error, names_error(names)}
  end

  defp names_from(other), do: {:error, names_error(other)}

  defp valid_names?(names) do
    names != [] and Enum.all?(names, &(is_binary(&1) and &1 != ""))
  end

  defp names_error(value) do
    "name must be an agent name or a list of agent names; got #{inspect(value)}."
  end
end
