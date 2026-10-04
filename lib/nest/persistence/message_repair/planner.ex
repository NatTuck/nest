defmodule Nest.Persistence.MessageRepair.Planner do
  @moduledoc """
  Pure planner for the offline message repair tool
  (`mix nest.repair_messages`).

  Given the persisted `agents` rows and their `messages` rows, it
  produces a `%Planner{}` describing the writes that bring every
  resolved sequence back to a wire-valid shape, without touching
  the database:

    * **pairing** — an assistant `Part.ToolUse` not answered by its
      immediate successor gets an `is_error: true` tool result
      inserted after it (or its following partial tool result is
      rewritten to include the missing results);
    * **orphan results** — a `{:tool, _}` whose result ids were already
      answered by an earlier tool row is a duplicate: its real payload
      replaces an earlier synthetic `is_error` result for the same id
      (when there is one), then the orphan row is deleted. An orphan
      that matches no earlier result is deleted too — it can never be
      paired without inventing an assistant;
    * **alternation** — two consecutive `user`/`assistant` wire
      roles get one opposite-role message inserted between them;
    * **renumbering** — the affected owner's own rows are made
      contiguous (inserts add rows, deletes remove them), and every
      clone sharing the changed prefix shifts its
      `fork_message_index` and own indices recursively.

  Synthetic rows are always owned by the agent being repaired, so
  an ancestor's repair shifts its descendants but never the other
  way around. Processing is root-first (pre-order) per `parent_id`
  tree, so a descendant always observes the already-shifted prefix.

  See `notes/enforce-mesages-seq-invariants.md` and
  `notes/shared-message-structure.md`.
  """

  alias Nest.Agents.PersistedAgent
  alias Nest.Agents.PersistedMessage
  alias Nest.LLM.Preflight
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  @type entry :: %{
          row: PersistedMessage.t() | nil,
          runtime: term(),
          index: integer()
        }

  @typedoc "A synthetic runtime message to insert, with its anchor."
  @type synthetic :: %{
          type: :tool | :ack | :continuation,
          results: [%Part.ToolResult{}] | nil,
          anchor: integer()
        }

  defstruct inserts: [],
            rewrites: [],
            deletes: [],
            renumbers: [],
            agent_updates: %{},
            original_violations: %{},
            residual_violations: %{},
            changed_agents: MapSet.new()

  @type t :: %__MODULE__{
          inserts: [map()],
          rewrites: [map()],
          deletes: [map()],
          renumbers: [map()],
          agent_updates: %{integer() => map()},
          original_violations: %{integer() => [Preflight.violation()]},
          residual_violations: %{integer() => [Preflight.violation()]},
          changed_agents: MapSet.t(integer())
        }

  @doc """
  Plan all repairs for the given agents and their message rows.

  `rows_by_agent` maps `agent_id` to that agent's rows ordered by
  `message_index` (as returned by
  `Nest.Persistence.Messages.load_rows_by_agent/1`).
  """
  @spec plan([PersistedAgent.t()], %{integer() => [PersistedMessage.t()]}) :: t()
  def plan(agents, rows_by_agent) do
    model = build_model(agents, rows_by_agent)
    originals = snapshot_violations(model, agents)
    model = process_roots(model)
    finalize(model, agents, originals)
  end

  # --- model ---

  defp build_model(agents, rows_by_agent) do
    known = MapSet.new(agents, & &1.id)

    %{
      by_id: Map.new(agents, &{&1.id, agent_entry(&1, rows_by_agent)}),
      children: children_map(agents, known),
      roots: root_ids(agents, known),
      inserts: [],
      rewrites: %{},
      deletes: [],
      changed: MapSet.new()
    }
  end

  defp agent_entry(agent, rows_by_agent) do
    own =
      rows_by_agent
      |> Map.get(agent.id, [])
      |> Enum.sort_by(& &1.message_index)
      |> Enum.map(fn row ->
        %{row: row, runtime: PersistedMessage.to_runtime(row), index: row.message_index}
      end)

    %{row: agent, own: own}
  end

  defp children_map(agents, known) do
    agents
    |> Enum.filter(fn a -> is_integer(a.parent_id) and MapSet.member?(known, a.parent_id) end)
    |> Enum.group_by(& &1.parent_id, & &1.id)
  end

  defp root_ids(agents, known) do
    agents
    |> Enum.filter(fn a -> is_nil(a.parent_id) or not MapSet.member?(known, a.parent_id) end)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp process_roots(model) do
    Enum.reduce(model.roots, model, fn id, acc -> process_subtree(acc, id) end)
  end

  defp process_subtree(model, id) do
    model = process_agent(model, id)

    model
    |> Map.get(:children, %{})
    |> Map.get(id, [])
    |> Enum.sort()
    |> Enum.reduce(model, fn child, acc -> process_subtree(acc, child) end)
  end

  defp process_agent(model, id) do
    full = resolve_full(model, id)
    ctx = %{agent_id: id, first_own: first_own_index(model, id), append: append_index(model, id)}
    {items, corr} = correct_sequence(full, ctx)
    apply_correction(model, id, items, corr)
  end

  # --- resolution ---

  defp resolve_full(model, id, seen \\ MapSet.new()) do
    entry = model.by_id[id]
    own = Enum.map(entry.own, fn e -> {e.runtime, id, e.row, e.index} end)
    parent_id = entry.row.parent_id
    fork = entry.row.fork_message_index

    if shared_parent?(parent_id, fork, model, seen) do
      parent_full = resolve_full(model, parent_id, MapSet.put(seen, id))
      prefix = Enum.filter(parent_full, fn {_rt, _owner, _row, idx} -> idx < fork end)
      prefix ++ own
    else
      own
    end
  end

  defp shared_parent?(parent_id, fork, model, seen) do
    is_integer(parent_id) and is_integer(fork) and Map.has_key?(model.by_id, parent_id) and
      not MapSet.member?(seen, parent_id)
  end

  defp first_own_index(model, id) do
    case model.by_id[id].own do
      [] -> model.by_id[id].row.fork_message_index || 0
      own -> own |> Enum.map(& &1.index) |> Enum.min()
    end
  end

  defp append_index(model, id) do
    case model.by_id[id].own do
      [] -> first_own_index(model, id)
      own -> own |> Enum.map(& &1.index) |> Enum.max() |> Kernel.+(1)
    end
  end

  # --- corrected sequence walk ---

  defp correct_sequence(full, ctx) do
    {items, state, corr} =
      Enum.reduce(full, {[], new_state(), new_corr()}, fn item, {items, state, corr} ->
        step(item, ctx, items, state, corr)
      end)

    {items, corr} = flush_pending(items, state, ctx, corr)
    {Enum.reverse(items), corr}
  end

  defp new_state, do: %{need: nil, last: nil}

  defp new_corr, do: %{rewrites: %{}, deletes: %{}}

  defp put_rewrite(corr, row, agent_id, runtime) do
    %{corr | rewrites: Map.put(corr.rewrites, row.id, %{agent_id: agent_id, runtime: runtime})}
  end

  defp put_delete(corr, row, agent_id, index) do
    %{corr | deletes: Map.put(corr.deletes, row.id, %{agent_id: agent_id, index: index})}
  end

  defp step({msg, owner, row, index}, ctx, items, state, corr) do
    {items, state, corr, consumed?} =
      resolve_pairing(msg, owner, row, index, ctx, items, state, corr)

    if consumed? do
      {items, state, corr}
    else
      {items, state} =
        maybe_alternation(items, state, wire_role(msg), anchor(owner, row, index, ctx))

      items = emit(items, {:existing, msg, owner, row, index})
      {items, advance(state, msg), corr}
    end
  end

  # A `{:tool, _}` with no pending `tool_use`: it can never be paired. Consume
  # it as a repair — fold a later real payload into an earlier synthetic error
  # result for the same id when possible, then delete the orphan row.
  defp resolve_pairing(
         {:tool, %Tool{} = tool},
         owner,
         row,
         index,
         ctx,
         items,
         %{need: nil} = state,
         corr
       ) do
    resolve_orphan_tool(tool, owner, row, index, ctx, items, state, corr)
  end

  defp resolve_pairing(_msg, _owner, _row, _index, _ctx, items, %{need: nil} = state, corr) do
    {items, state, corr, false}
  end

  defp resolve_pairing(
         {:tool, %Tool{} = tool},
         owner,
         row,
         index,
         ctx,
         items,
         state,
         corr
       ) do
    resolve_tool(tool, owner, row, index, ctx, items, state, corr)
  end

  defp resolve_pairing(_msg, owner, row, index, ctx, items, state, corr) do
    emit_unpaired_tool(owner, row, index, ctx, items, state, corr)
  end

  defp resolve_tool(tool, owner, row, index, ctx, items, state, corr) do
    missing = missing_tool_uses(tool, state.need)
    answered? = missing != state.need

    cond do
      missing == [] ->
        {items, %{state | need: nil}, corr, false}

      owner == ctx.agent_id ->
        merged = merge_tool(tool, missing)
        corr = put_rewrite(corr, row, owner, {:tool, merged})
        item = {:existing, {:tool, merged}, owner, row, row.message_index}
        {emit(items, item), %{state | need: nil, last: :user}, corr, true}

      # A non-owned (shared-prefix) tool row that answers only some of the
      # pending uses: the owner's own pass already merges its remaining
      # results, so the child sees a complete prefix. Clear `need` without
      # emitting a repair rather than synthesizing a second result under
      # the ancestor (see `a partially answered shared-prefix tool batch`
      # in the planner tests).
      answered? ->
        {items, %{state | need: nil}, corr, false}

      true ->
        emit_unpaired_tool(owner, row, index, ctx, items, state, corr)
    end
  end

  defp emit_unpaired_tool(owner, row, index, ctx, items, state, corr) do
    results = Enum.map(state.need, &MessageList.unpaired_tool_result/1)
    synth = %{type: :tool, results: results, anchor: anchor(owner, row, index, ctx)}
    {emit(items, {:synthetic, synth}), %{state | need: nil, last: :user}, corr, false}
  end

  # --- orphan tool results ---

  defp resolve_orphan_tool(tool, owner, row, index, ctx, items, state, corr) do
    {items, corr} = consolidate_orphan(items, tool_result_ids(tool), tool, ctx.agent_id, corr)

    corr =
      if owner == ctx.agent_id do
        put_delete(corr, row, owner, index)
      else
        corr
      end

    {items, state, corr, true}
  end

  # Fold an orphan's real payload into the most recent tool message that
  # already answered a matching id, but only when that earlier result is a
  # synthetic `is_error` result (the later real result is strictly better).
  # A synthetic still in the emitted list is patched in place; an existing
  # row is rewritten. No match (or no error to replace) leaves the orphan a
  # plain delete.
  defp consolidate_orphan(items, ids, orphan, agent_id, corr) do
    case find_answer(items, ids) do
      {:existing, {:tool, %Tool{} = answer}, ^agent_id, row, _idx} ->
        merged = %Tool{
          answer
          | parts: merge_real_results(answer.parts || [], orphan.parts || [], ids)
        }

        if merged == answer do
          {items, corr}
        else
          corr = put_rewrite(corr, row, agent_id, {:tool, merged})
          {replace_existing(items, row.id, {:tool, merged}), corr}
        end

      {:synthetic, %{type: :tool, results: results} = synth} ->
        patched = %{synth | results: merge_real_results(results, orphan.parts || [], ids)}
        {replace_synthetic(items, synth, patched), corr}

      _ ->
        {items, corr}
    end
  end

  defp find_answer(items, ids) do
    Enum.find(items, fn
      {:existing, {:tool, %Tool{parts: parts}}, _owner, _row, _idx} ->
        answers_ids?(parts || [], ids)

      {:synthetic, %{type: :tool, results: results}} ->
        answers_ids?(results, ids)

      _ ->
        false
    end)
  end

  defp answers_ids?(parts, ids) do
    Enum.any?(parts, fn
      %Part.ToolResult{tool_call_id: id} -> id in ids
      _ -> false
    end)
  end

  defp merge_real_results(parts, orphan_parts, ids) do
    Enum.map(parts, fn
      %Part.ToolResult{tool_call_id: id, is_error: true} = error ->
        if id in ids, do: real_result(orphan_parts, id) || error, else: error

      part ->
        part
    end)
  end

  defp real_result(parts, id) do
    Enum.find(parts, fn
      %Part.ToolResult{tool_call_id: ^id, is_error: false} = result -> result
      _ -> false
    end)
  end

  defp replace_existing(items, row_id, runtime) do
    Enum.map(items, fn
      {:existing, _msg, owner, %{id: ^row_id} = row, idx} -> {:existing, runtime, owner, row, idx}
      other -> other
    end)
  end

  defp replace_synthetic(items, old, new) do
    Enum.map(items, fn
      {:synthetic, ^old} -> {:synthetic, new}
      other -> other
    end)
  end

  defp tool_result_ids(%Tool{parts: parts}) do
    for %Part.ToolResult{tool_call_id: id} <- parts || [], do: id
  end

  defp missing_tool_uses(tool, need) do
    answered = for %Part.ToolResult{tool_call_id: id} <- tool.parts || [], do: id
    Enum.reject(need, fn tool_use -> tool_use.id in answered end)
  end

  defp merge_tool(tool, missing) do
    %Tool{
      tool
      | parts: (tool.parts || []) ++ Enum.map(missing, &MessageList.unpaired_tool_result/1)
    }
  end

  defp flush_pending(items, %{need: nil}, _ctx, corr), do: {items, corr}

  defp flush_pending(items, %{need: need}, ctx, corr) do
    results = Enum.map(need, &MessageList.unpaired_tool_result/1)
    synth = %{type: :tool, results: results, anchor: ctx.append}
    {emit(items, {:synthetic, synth}), corr}
  end

  defp maybe_alternation(items, %{last: role} = state, role, anchor)
       when role in [:user, :assistant] do
    synth =
      if role == :user,
        do: %{type: :ack, anchor: anchor},
        else: %{type: :continuation, anchor: anchor}

    {emit(items, {:synthetic, synth}), %{state | last: opposite(role)}}
  end

  defp maybe_alternation(items, state, _wire, _anchor), do: {items, state}

  defp opposite(:user), do: :assistant
  defp opposite(:assistant), do: :user

  defp advance(state, {:assistant, %Assistant{parts: parts}}) do
    case tool_uses(parts) do
      [] -> %{state | need: nil, last: :assistant}
      ids -> %{state | need: ids, last: :assistant}
    end
  end

  defp advance(state, {:user, _}), do: %{state | need: nil, last: :user}
  defp advance(state, {:tool, _}), do: %{state | need: nil, last: :user}
  defp advance(state, _ignored), do: state

  defp tool_uses(parts), do: for(%Part.ToolUse{} = tu <- parts || [], do: tu)

  defp wire_role({:assistant, _}), do: :assistant
  defp wire_role({:user, _}), do: :user
  defp wire_role({:tool, _}), do: :user
  defp wire_role(_ignored), do: nil

  defp anchor(owner, row, index, ctx) do
    if owner == ctx.agent_id and not is_nil(row), do: index, else: ctx.first_own
  end

  defp emit(items, item), do: [item | items]

  # --- applying a correction to the model ---

  defp apply_correction(model, agent_id, items, corr) do
    {_prefix, own_items} = split_own(items, agent_id)

    if Enum.any?(own_items, &synthetic?/1) or map_size(corr.rewrites) > 0 or
         map_size(corr.deletes) > 0 do
      first_own = first_own_index(model, agent_id)
      {entries, inserts} = build_entries(own_items, agent_id, first_own)
      model = put_corrected(model, agent_id, entries, first_own)

      model = %{
        model
        | inserts: model.inserts ++ inserts,
          rewrites: Map.merge(model.rewrites, corr.rewrites),
          deletes: model.deletes ++ delete_entries(corr.deletes)
      }

      model = %{model | changed: MapSet.put(model.changed, agent_id)}
      shift_descendants(model, agent_id, anchors(own_items), delete_anchors(corr.deletes))
    else
      model
    end
  end

  defp delete_entries(deletes) do
    for {id, %{agent_id: agent_id, index: index}} <- deletes,
        do: %{id: id, agent_id: agent_id, index: index}
  end

  defp delete_anchors(deletes), do: for({_id, %{index: index}} <- deletes, do: index)

  defp split_own(items, agent_id) do
    Enum.split_while(items, fn
      {:synthetic, _synth} -> false
      {:existing, _msg, owner, _row, _idx} -> owner != agent_id
    end)
  end

  defp synthetic?({:synthetic, _synth}), do: true
  defp synthetic?(_item), do: false

  defp anchors(own_items) do
    for {:synthetic, synth} <- own_items, do: synth.anchor
  end

  defp build_entries(own_items, agent_id, first_own) do
    {entries, inserts} =
      own_items
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {item, pos}, {entries, inserts} ->
        {entry, insert} = entry_for(item, first_own + pos, agent_id)
        {[entry | entries], if(insert, do: [insert | inserts], else: inserts)}
      end)

    {Enum.reverse(entries), Enum.reverse(inserts)}
  end

  defp entry_for({:existing, runtime, _owner, row, _old}, index, _agent_id) do
    {%{row: row, runtime: runtime, index: index}, nil}
  end

  defp entry_for({:synthetic, synth}, index, agent_id) do
    runtime = build_synthetic(synth, index)
    entry = %{row: nil, runtime: runtime, index: index}
    {entry, %{agent_id: agent_id, index: index, runtime: runtime}}
  end

  defp build_synthetic(%{type: :tool, results: results}, index) do
    {:tool, %Tool{index: index, parts: results, api_logs: []}}
  end

  defp build_synthetic(%{type: :ack}, index) do
    {:assistant, assistant} = MessageList.repair_ack()
    {:assistant, %{assistant | index: index}}
  end

  defp build_synthetic(%{type: :continuation}, index) do
    {:user, user} = MessageList.continuation_prompt()
    {:user, %{user | index: index}}
  end

  defp put_corrected(model, agent_id, entries, first_own) do
    entry = model.by_id[agent_id]

    row = %{
      entry.row
      | next_message_index: first_own + length(entries),
        last_compaction_index: shifted_boundary(entry.row.last_compaction_index, entries)
    }

    %{model | by_id: Map.put(model.by_id, agent_id, %{entry | row: row, own: entries})}
  end

  defp shifted_boundary(-1, _entries), do: -1

  defp shifted_boundary(old, entries) do
    case Enum.find(entries, fn e -> not is_nil(e.row) and e.row.message_index == old end) do
      nil -> old
      entry -> entry.index
    end
  end

  # --- recursive descendant shifts ---

  defp shift_descendants(model, parent_id, synth_anchors, delete_anchors) do
    model
    |> Map.get(:children, %{})
    |> Map.get(parent_id, [])
    |> Enum.reduce(model, fn child_id, acc ->
      shift_child(acc, child_id, synth_anchors, delete_anchors)
    end)
  end

  defp shift_child(model, child_id, synth_anchors, delete_anchors) do
    case model.by_id[child_id].row.fork_message_index do
      nil ->
        model

      fork ->
        inserts = Enum.count(synth_anchors, fn anchor -> anchor < fork end)
        deletes = Enum.count(delete_anchors, fn anchor -> anchor < fork end)
        delta = inserts - deletes
        if delta != 0, do: shift_subtree(model, child_id, delta), else: model
    end
  end

  defp shift_subtree(model, id, delta) do
    entry = model.by_id[id]
    row = shift_row(entry.row, delta)
    own = Enum.map(entry.own, fn e -> %{e | index: e.index + delta} end)
    model = %{model | by_id: Map.put(model.by_id, id, %{entry | row: row, own: own})}
    model = %{model | changed: MapSet.put(model.changed, id)}

    model
    |> Map.get(:children, %{})
    |> Map.get(id, [])
    |> Enum.reduce(model, fn child_id, acc ->
      if is_integer(acc.by_id[child_id].row.fork_message_index) do
        shift_subtree(acc, child_id, delta)
      else
        acc
      end
    end)
  end

  defp shift_row(row, delta) do
    %{
      row
      | fork_message_index: shift_optional(row.fork_message_index, delta),
        next_message_index: row.next_message_index + delta,
        last_compaction_index: shift_boundary(row.last_compaction_index, delta)
    }
  end

  defp shift_optional(nil, _delta), do: nil
  defp shift_optional(value, delta), do: value + delta

  defp shift_boundary(-1, _delta), do: -1
  defp shift_boundary(value, delta), do: value + delta

  # --- validation snapshots ---

  defp snapshot_violations(model, agents) do
    agents
    |> Enum.map(fn agent -> {agent.id, violations_for(model, agent.id)} end)
    |> Enum.reject(fn {_id, violations} -> violations == [] end)
    |> Map.new()
  end

  defp violations_for(model, id) do
    model
    |> resolve_full(id)
    |> Enum.map(fn {runtime, _owner, _row, _idx} -> runtime end)
    |> Preflight.validate()
    |> case do
      :ok -> []
      {:error, violations} -> violations
    end
  end

  defp finalize(model, agents, originals) do
    changed = model.changed

    renumbers =
      for id <- changed, e <- model.by_id[id].own, not is_nil(e.row), do: renumber(e, id)

    %__MODULE__{
      inserts: model.inserts,
      rewrites:
        Enum.map(model.rewrites, fn {row_id, %{agent_id: aid, runtime: rt}} ->
          %{id: row_id, agent_id: aid, runtime: rt}
        end),
      deletes: model.deletes,
      renumbers: renumbers,
      agent_updates: Map.new(changed, fn id -> {id, update_map(model.by_id[id].row)} end),
      original_violations: originals,
      residual_violations: snapshot_violations(model, agents),
      changed_agents: changed
    }
  end

  defp renumber(entry, agent_id), do: %{id: entry.row.id, agent_id: agent_id, index: entry.index}

  defp update_map(row) do
    %{
      next_message_index: row.next_message_index,
      fork_message_index: row.fork_message_index,
      last_compaction_index: row.last_compaction_index
    }
  end
end
