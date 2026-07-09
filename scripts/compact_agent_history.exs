# One-off compaction for an agent whose in-process state is
# stuck (typically because a previous compaction crashed
# mid-flight).
#
# Run with:
#
#     mix run scripts/compact_agent_history.exs <agent_name>
#
# The script:
#   1. Reads the agent row + all active (non-archived) messages.
#   2. Archives every active row, separating the canonical
#      pre-compaction slice (message_index < pre_compaction_cutoff)
#      from any orphan rows that a previous crashed compaction
#      left behind (message_index >= pre_compaction_cutoff).
#   3. Runs Nest.Tokens.Compactor on the canonical slice and
#      re-encodes the output the same way
#      `CompactionHandler.regenerate_for_compaction/2` does on
#      the live agent:
#        - Position 0: fresh system (re-rendered from the
#          agent's current Vocation)
#        - Position 1: encoded summary as a user message
#        - Positions 2..N: compactor's other output,
#          renumbered
#   4. Inserts a compaction marker at the agent's
#      `next_message_index` and the new compacted state
#      immediately after.
#   5. Bumps `next_message_index` past the new state.
#
# Idempotency: if the agent's message history is already
# post-compaction (a marker exists at `next_message_index - 1`
# and there are no unarchived rows below it), the script
# logs a notice and exits without writing. Pass `--force` to
# skip the sanity check (use with care).
#
# Why this is a script and not a mix task: the operation
# is one-off recovery for a specific incident (the
# `overall-crawdad` crash from 2026-07-03) and shouldn't
# be wired into the regular agent lifecycle.

defmodule Nest.Scripts.CompactAgentHistory do
  @moduledoc false

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Repo
  alias Nest.Scripts.CompactionProbeSupport
  alias Nest.Tokens.Compactor
  alias Nest.Vocations

  require Logger

  import Ecto.Query

  def run(argv) do
    {opts, positional, _invalid} =
      OptionParser.parse(argv,
        strict: [force: :boolean, dry_run: :boolean],
        aliases: [f: :force, n: :dry_run]
      )

    agent_name =
      case positional do
        [name | _] -> name
        [] -> raise "usage: mix run scripts/compact_agent_history.exs <agent_name> [--force] [--dry-run]"
      end

    force = opts[:force] || false
    dry_run = opts[:dry_run] || false

    Logger.info("Starting one-off compaction for agent: #{agent_name} (force=#{force}, dry_run=#{dry_run})")

    with {:ok, agent} <- load_agent(agent_name),
         {:ok, slice, orphans} <- partition_messages(agent),
         :ok <- sanity_check(agent, slice, orphans, force),
         {:ok, client_config, context_limit} <- build_client_config(agent),
         {:ok, fresh_system_text, _fresh_vocation} <- build_fresh_system(agent),
         {:ok, compactor_output} <- run_compactor(slice, context_limit, client_config),
         {:ok, new_messages} <- re_encode(compactor_output, fresh_system_text, agent.next_message_index),
         :ok <- write_to_db(agent, new_messages, length(slice) + length(orphans), dry_run) do
      log_summary(agent, slice, orphans, new_messages, dry_run)
    else
      :bail ->
        Logger.info("Exit: 0 (nothing to compact)")
        :ok

      {:error, reason} ->
        Logger.error("Compaction failed: #{inspect(reason)}")
        Elixir.System.halt(1)
    end
  end

  # Load the agent row by name.
  defp load_agent(name) do
    case Persistence.fetch_agent_by_name(name) do
      {:ok, %PersistedAgent{} = agent} ->
        Logger.info("Loaded agent: id=#{agent.id} vocation_id=#{agent.vocation_id} next_message_index=#{agent.next_message_index}")
        {:ok, agent}

      {:error, :not_found} ->
        {:error, {:agent_not_found, name}}
    end
  end

  # Read all active messages and partition them into the
  # canonical pre-compaction slice (the last contiguous run
  # of non-orphan rows) and the orphan rows (anything past
  # the slice's last index, e.g. the rows a crashed
  # compaction's `regenerate_for_compaction/2` persisted
  # but whose marker INSERT never made it).
  defp partition_messages(%PersistedAgent{} = agent) do
    rows =
      from(m in PersistedMessage,
        where: m.agent_id == ^agent.id and is_nil(m.archived_at) and m.role != "compaction",
        order_by: [asc: m.message_index]
      )
      |> Repo.all()

    # Find the largest contiguous run starting at message_index
    # 0. A previous successful compaction would have advanced
    # `next_message_index` past the marker; if it didn't, there
    # might be a gap.
    {slice, orphans} = split_orphans(rows, [])

    Logger.info("Partition: slice=#{length(slice)} orphans=#{length(orphans)}")

    {:ok, Enum.reverse(slice), orphans}
  end

  defp split_orphans([], acc), do: {acc, []}

  defp split_orphans([%{message_index: idx} = row | rest], acc) do
    expected = length(acc)

    if idx == expected do
      split_orphans(rest, [row | acc])
    else
      # Gap detected; everything from here is orphan.
      {acc, [row | rest]}
    end
  end

  # Sanity check: bail with a notice if the agent's history
  # is already in a sane post-compaction state. Pass --force
  # to skip this check.
  defp sanity_check(_agent, [], _orphans, _force) do
    Logger.info("No pre-compaction slice found; agent is already in a post-compaction state. Pass --force to override.")
    :bail
  end

  defp sanity_check(agent, slice, orphans, force) do
    last_index = hd(Enum.reverse(slice)).message_index

    if last_index + 1 == agent.next_message_index and orphans == [] do
      if force do
        Logger.warning("Sanity check failed but --force passed; continuing")
        :ok
      else
        Logger.info("Agent #{agent.name} is in a sane post-compaction state; nothing to do. Pass --force to override.")
        :bail
      end
    else
      :ok
    end
  end

  # Removed `halt_clean/0` — the `with` block's `else` clause
  # handles the `:bail` sentinel and logs the exit.

  # Build the ClientConfig from the agent row's model + dotconfig.
  # Delegates to `CompactionProbeSupport` so the probe script and
  # this recovery script agree on the exact provider resolution +
  # LLM call shape. If those diverge, a probe that says "the LLM
  # works" is meaningless because production would still fail.
  defp build_client_config(%PersistedAgent{} = agent) do
    case CompactionProbeSupport.build_client_config(agent.model) do
      {:ok, cc, context_limit} -> {:ok, cc, context_limit}
      {:error, :provider_not_in_dotconfig} = err -> err
      {:error, reason} -> {:error, {:dotconfig_load_failed, reason}}
    end
  end

  # Re-render the fresh system prompt from the agent's
  # current Vocation row.
  defp build_fresh_system(%PersistedAgent{} = agent) do
    case Vocations.get_vocation(agent.vocation_id) do
      nil ->
        {:error, {:vocation_not_found, agent.vocation_id}}

      %Vocations.Vocation{} = vocation ->
        text = vocation.system_prompt || ""
        {:ok, text, vocation}
    end
  end

  # Run the compactor. Returns the compactor's output list
  # (which always starts with a `{:system, _}` carrying the
  # summary text).
  defp run_compactor(slice, context_limit, client_config) do
    messages = Enum.map(slice, &PersistedMessage.to_runtime/1)

    Logger.info("Running compactor on #{length(messages)} messages (context_limit=#{context_limit})")

    # Compute the summary budget (N) and pre-render the
    # `[mode: compact]` suffix. The LLM call uses the rendered
    # suffix directly — no re-render at call time, so the size
    # we budgeted for matches what goes on the wire.
    system_msg = Enum.find(messages, &match?({:system, _}, &1)) || {:system, %{parts: []}}

    case Compactor.compute_summary_budget(context_limit, system_msg, messages, nil) do
      {:ok, _n, rendered_suffix} ->
        llm_call =
          CompactionProbeSupport.build_summarization_llm_call(
            client_config,
            self(),
            rendered_suffix
          )

        try do
          result = Compactor.compact(messages, context_limit, llm_call)
          {:ok, result}
        catch
          kind, reason ->
            {:error, {:compactor_crashed, kind, reason}}
        end

      {:error, :reserve_exhausted} ->
        {:error, :reserve_exhausted}
    end
  end

  # Re-encode the compactor's output the same way
  # `CompactionHandler.regenerate_for_compaction/2` does on
  # the live agent:
  #   - marker at next_message_index (inserted separately)
  #   - Position 0 of the new state (marker_index + 1):
  #     fresh system (re-rendered from current Vocation)
  #   - Position 1 (marker_index + 2): encoded summary as a
  #     user message
  #   - Positions 2..N (marker_index + 3 onwards): compactor's
  #     other output, renumbered
  defp re_encode(compactor_output, fresh_system_text, marker_index) do
    [{:system, %System{parts: [%Part.Text{text: summary_text}]}} | rest] = compactor_output

    fresh_system =
      {:system,
       %System{
         index: marker_index + 1,
         parts: [%Part.Text{text: fresh_system_text}],
         timestamp: DateTime.utc_now(),
         api_logs: []
       }}

    summary_user =
      {:user,
       %User{
         index: marker_index + 2,
         parts: [%Part.Text{text: "Summary of earlier conversation:\n\n" <> summary_text}],
         timestamp: DateTime.utc_now(),
         api_logs: []
       }}

    renumbered_rest = renumber(rest, marker_index + 3)

    {:ok, [fresh_system, summary_user | renumbered_rest]}
  end

  defp renumber(messages, start_index) do
    {result, _} =
      Enum.map_reduce(messages, start_index, fn msg, idx ->
        {assign_index(msg, idx), idx + 1}
      end)

    result
  end

  defp assign_index({role, %_{} = struct}, idx) do
    {role, %{struct | index: idx}}
  end

  # Archive all active rows, insert the marker, insert the
  # new compacted state, bump next_message_index. One
  # transaction so the agent is never observed in a
  # half-applied state.
  defp write_to_db(%PersistedAgent{} = agent, new_messages, archived_count, dry_run) do
    new_count = length(new_messages)
    marker_index = agent.next_message_index
    new_last_index = marker_index + new_count
    new_next_index = new_last_index + 1

    Logger.info("""
    Plan:
      archive rows: message_index < #{marker_index} (#{archived_count} messages)
      marker at:    #{marker_index} (role: compaction)
      new state:    #{marker_index + 1}..#{new_last_index} (#{new_count} messages)
      next_message_index: #{new_next_index}
    """)

    if dry_run do
      Logger.info("--dry-run passed; not writing")
      :ok
    else
      do_write(agent, new_messages, marker_index, new_next_index, archived_count)
    end
  end

  defp do_write(agent, new_messages, marker_index, new_next_index, archived_count) do
    Repo.transaction(fn ->
      # Archive all active rows below the marker index
      # (the canonical slice + the orphan rows).
      from(m in PersistedMessage,
        where:
          m.agent_id == ^agent.id and is_nil(m.archived_at) and m.message_index < ^marker_index
      )
      |> Repo.update_all(set: [archived_at: DateTime.utc_now() |> DateTime.truncate(:second)])

      # Insert the marker.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %PersistedMessage{}
      |> PersistedMessage.changeset(%{
        agent_id: agent.id,
        message_index: marker_index,
        role: "compaction",
        content: %{"parts" => []},
        inserted_at: now,
        compaction_archived_count: archived_count,
        compaction_occurred_at: now
      })
      |> Repo.insert!()

      # Insert the new compacted state. Use
      # `on_conflict: :nothing` so a partial replay (e.g. if
      # this script is re-run after a crash) is idempotent.
      Enum.each(new_messages, fn {role, struct} = message ->
        attrs = PersistedMessage.from_runtime(agent.id, message)

        %PersistedMessage{}
        |> PersistedMessage.changeset(attrs)
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:agent_id, :message_index])

        Logger.info("  inserted #{role} at index #{struct.index}")
      end)

      # Bump the agent's next_message_index.
      from(a in PersistedAgent, where: a.id == ^agent.id)
      |> Repo.update_all(
        set: [
          next_message_index: new_next_index,
          updated_at: now
        ]
      )
    end)
    |> case do
      {:ok, _} ->
        Logger.info("DB write complete")
        :ok

      {:error, reason} ->
        {:error, {:db_write_failed, reason}}
    end
  end

  defp log_summary(agent, slice, orphans, new_messages, dry_run) do
    Logger.info("""

    Summary:
      agent:               #{agent.name}
      archived slice:       #{length(slice)} messages
      archived orphans:     #{length(orphans)} messages
      new compacted state:  #{length(new_messages)} messages
      new next_message_idx: #{agent.next_message_index + length(new_messages) + 1}
      dry_run:              #{dry_run}
    """)
  end
end

Nest.Scripts.CompactAgentHistory.run(System.argv())
