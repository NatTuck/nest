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
    * **alternation** — two consecutive `user`/`assistant` wire
      roles get one opposite-role message inserted between them;
    * **renumbering** — the affected owner's own rows are made
      contiguous, and every clone sharing the changed prefix shifts
      its `fork_message_index` and own indices recursively.

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
            renumbers: [],
            agent_updates: %{},
            original_violations: %{},
            residual_violations: %{},
            changed_agents: MapSet.new()

  @type t :: %__MODULE__{
          inserts: [map()],
          rewrites: [map()],
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
    {items, rewrites} = correct_sequence(full, ctx)
    apply_correction(model, id, items, rewrites)
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
    {items, state, rewrites} =
      Enum.reduce(full, {[], new_state(), %{}}, fn item, {items, state, rewrites} ->
        step(item, ctx, items, state, rewrites)
      end)

    {items, rewrites} = flush_pending(items, state, ctx, rewrites)
    {Enum.reverse(items), rewrites}
  end

  defp new_state, do: %{need: nil, last: nil}

  defp step({msg, owner, row, index}, ctx, items, state, rewrites) do
    {items, state, rewrites, consumed?} =
      resolve_pairing(msg, owner, row, index, ctx, items, state, rewrites)

    if consumed? do
      {items, state, rewrites}
    else
      {items, state} =
        maybe_alternation(items, state, wire_role(msg), anchor(owner, row, index, ctx))

      items = emit(items, {:existing, msg, owner, row, index})
      {items, advance(state, msg), rewrites}
    end
  end

  defp resolve_pairing(_msg, _owner, _row, _index, _ctx, items, %{need: nil} = state, rewrites) do
    {items, state, rewrites, false}
  end

  defp resolve_pairing(
         {:tool, %Tool{} = tool} = _msg,
         owner,
         row,
         _index,
         %{agent_id: aid} = _ctx,
         items,
         state,
         rewrites
       )
       when owner == aid do
    resolve_partial_tool(tool, owner, row, items, state, rewrites)
  end

  defp resolve_pairing(_msg, owner, row, index, ctx, items, state, rewrites) do
    emit_unpaired_tool(owner, row, index, ctx, items, state, rewrites)
  end

  defp resolve_partial_tool(tool, owner, row, items, state, rewrites) do
    missing = missing_tool_uses(tool, state.need)

    if missing == [] do
      {items, %{state | need: nil}, rewrites, false}
    else
      merged = merge_tool(tool, missing)
      rewrites = Map.put(rewrites, row.id, %{agent_id: owner, runtime: {:tool, merged}})
      item = {:existing, {:tool, merged}, owner, row, row.message_index}
      {emit(items, item), %{state | need: nil, last: :user}, rewrites, true}
    end
  end

  defp emit_unpaired_tool(owner, row, index, ctx, items, state, rewrites) do
    results = Enum.map(state.need, &MessageList.unpaired_tool_result/1)
    synth = %{type: :tool, results: results, anchor: anchor(owner, row, index, ctx)}
    {emit(items, {:synthetic, synth}), %{state | need: nil, last: :user}, rewrites, false}
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

  defp flush_pending(items, %{need: nil}, _ctx, rewrites), do: {items, rewrites}

  defp flush_pending(items, %{need: need}, ctx, rewrites) do
    results = Enum.map(need, &MessageList.unpaired_tool_result/1)
    synth = %{type: :tool, results: results, anchor: ctx.append}
    {emit(items, {:synthetic, synth}), rewrites}
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

  defp apply_correction(model, agent_id, items, rewrites) do
    {_prefix, own_items} = split_own(items, agent_id)

    if Enum.any?(own_items, &synthetic?/1) or map_size(rewrites) > 0 do
      first_own = first_own_index(model, agent_id)
      {entries, inserts} = build_entries(own_items, agent_id, first_own)
      model = put_corrected(model, agent_id, entries, first_own)

      model = %{
        model
        | inserts: model.inserts ++ inserts,
          rewrites: Map.merge(model.rewrites, rewrites)
      }

      model = %{model | changed: MapSet.put(model.changed, agent_id)}
      shift_descendants(model, agent_id, anchors(own_items))
    else
      model
    end
  end

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

  defp shift_descendants(model, parent_id, synth_anchors) do
    model
    |> Map.get(:children, %{})
    |> Map.get(parent_id, [])
    |> Enum.reduce(model, fn child_id, acc -> shift_child(acc, child_id, synth_anchors) end)
  end

  defp shift_child(model, child_id, synth_anchors) do
    case model.by_id[child_id].row.fork_message_index do
      nil ->
        model

      fork ->
        delta = Enum.count(synth_anchors, fn anchor -> anchor < fork end)
        if delta > 0, do: shift_subtree(model, child_id, delta), else: model
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
