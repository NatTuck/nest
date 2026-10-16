defmodule Nest.Agents.Agent.Init do
  @moduledoc """
  Initial state construction for the agent GenServer.
  Extracted from `Nest.Agents.Agent` so the GenServer module
  stays small.

  The `init/1` callback delegates to `build_state/2` here for
  the struct construction and to `seed_from_db/4` for hydrating
  the persisted message sequence. Both are pure — no side
  effects, no DB access (see the hard rule in
  `Nest.Agents.Agent.init/1`). The initial system message row and
  the load-time sequence heal are written by the *caller*, in
  `Agent.pre_spawn/1` and `Agent.pre_load_heal/1`.
  """

  require Logger

  @default_limit 128_000

  # Tools that let an agent spawn further sub-agents. Dropped
  # from the tool list of non-clone agents spawned at max depth.
  @spawn_tools ~w(agents-spawn agents-batch)

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Persistence, as: AgentPersistence
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.Agent.TreePosition
  alias Nest.Agents.Agent.Turn.ContextReminder
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Sandbox.Mounts
  alias Nest.Tools

  @doc """
  Build the initial state struct. Pure: no DB access, no
  broadcasts, no logging.

  The caller is responsible for providing the loaded vocation
  struct via `:vocation` in `attrs` (typically fetched via
  `Persistence.load_vocation/1` or `Vocations.get_vocation/1`
  in the calling process). This keeps `init/1` free of DB
  work, which is what lets the agent run in async tests with
  `$callers` walking instead of per-pid `Sandbox.allow`.
  """
  @spec build_state(map(), Nest.LLM.ClientConfig.t()) :: Nest.Agents.Agent.t()
  def build_state(attrs, client_config) do
    backend = Map.fetch!(attrs, :sandbox_backend)
    workspace = Map.get(attrs, :workspace_path)

    name = Map.fetch!(attrs, :name)
    space_id = Map.fetch!(attrs, :space_id)

    # The agent's whole sandbox, built once: the backend its space runs, the
    # workspace it binds, and the scratch directory just created for it. The
    # tools capture it (a tool closure runs the command it is handed through
    # this value), and composing the prompt runs the sandbox too, so both must
    # carry the real backend and the real scratch — a `"none"` space's reads
    # must not run under bwrap, and a `"docker"` one can only stage through the
    # scratch bind (see `Nest.Sandbox.Backend.Docker.command/3`).
    mounts = Mounts.new(workspace, create_tmp_space(space_id, name, backend), backend, space_id)

    {system_prompt, mode, tool_names, cached_vocation, llm_metrics} =
      build_vocation_pipeline(attrs, mounts)

    tools = Tools.get_functions(tool_names, mounts)

    {initial_messages, next_index} = initial_messages_with_system(system_prompt)

    %Nest.Agents.Agent{
      name: name,
      space_id: space_id,
      model: Map.fetch!(attrs, :model),
      client_config: client_config,
      vocation: cached_vocation,
      vocation_id: Map.fetch!(attrs, :vocation_id),
      mounts: mounts,
      tools: tools,
      llm_metrics: llm_metrics,
      tree_position: %TreePosition{
        parent_id: Map.get(attrs, :parent_id),
        parent_name: Map.get(attrs, :parent_name),
        fork_message_index: Map.get(attrs, :fork_message_index)
      },
      created_by_user_id: Map.get(attrs, :created_by_user_id),
      shared: Map.get(attrs, :shared, false),
      depth: Map.get(attrs, :depth, 0),
      chat_state: build_chat_state(initial_messages, next_index, Map.get(attrs, :agent_row_id)),
      live: build_live_state(mode)
    }
  end

  # Vocation-derived attributes: context limit, system prompt,
  # tool list, cached vocation struct, and the `llm_metrics`
  # initializer. Kept as its own helper so `build_state/2`
  # stays under the credo ABC cap.
  #
  # The prompt is composed through `mounts` because composing it *runs* the
  # sandbox: the `AGENTS.md` section reads the file through it (see
  # `Nest.Agents.Agent.TmpSpace.prompt_mounts/4`).
  defp build_vocation_pipeline(attrs, mounts) do
    model = Map.fetch!(attrs, :model)
    # Internal/test-only cache-tier override; see `initial_context_limit/2`.
    cache_lookup = Map.get(attrs, :context_limit_lookup, &Nest.Models.context_limit/2)
    {context_limit, context_limit_source} = initial_context_limit(model, cache_lookup)

    {system_prompt, mode, tool_names, cached_vocation} =
      SystemPrompt.compose_vocation_config(
        Map.get(attrs, :vocation),
        mounts,
        {context_limit, context_limit_source},
        Map.get(attrs, :name, ""),
        Map.get(attrs, :depth, 0)
      )

    tool_names = maybe_exclude_spawn(tool_names, attrs)

    {system_prompt, mode, tool_names, cached_vocation,
     build_llm_metrics(context_limit, context_limit_source)}
  end

  # Non-clone agents spawned at max depth must not be able to
  # spawn children, so `agents-spawn` and `agents-batch` are
  # dropped from their tool list. Clones never set
  # `:exclude_spawn` — they must keep the exact tool list of
  # their parent (hard rule).
  defp maybe_exclude_spawn(tool_names, %{exclude_spawn: true}),
    do: Enum.reject(tool_names, &(&1 in @spawn_tools))

  defp maybe_exclude_spawn(tool_names, _attrs), do: tool_names

  @doc """
  Persist the initial system message built by `build_state/2`
  into the `messages` table. No-op when persistence is disabled
  or when the agent's `chat_state.messages` list is empty.

  This function is retained for direct callers that want to
  pre-persist a system message row outside of `Agent.pre_spawn/1`
  — for example, the regression test in `agent_persistence_test.exs`
  that pins the wrapper's idempotency contract. `Agent.init/1`
  no longer calls this; the canonical pre-spawn write lives in
  `Agent.pre_spawn/1` (in the calling process's DB context).
  """
  @spec persist_initial_system_message(Nest.Agents.Agent.t()) :: :ok
  def persist_initial_system_message(state) do
    case state.chat_state.messages do
      [{:system, sys_struct} | _] when is_struct(sys_struct, System) ->
        AgentPersistence.append_message(
          state,
          {:system, sys_struct},
          state.chat_state.next_message_index
        )

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Seed the agent's `chat_state` from the loaded message sequence.

  `preloaded` is the **active slice** — the rows above
  `last_compaction_index`, as returned by
  `Persistence.build_attrs_for_start/2`. The rows at or below the boundary
  are the archive, which the runtime never holds: `ChatState` keeps only
  `messages` and the archive is derived on demand by
  `Nest.Persistence.History`. So the load path reads the archived rows as a
  projection and passes the three facts it needs about them in `archived`
  (see `Persistence.Messages.archived_summary/3`): whether a system row
  exists anywhere in the logical sequence, the highest index the archive
  reaches, and how many compaction markers sit at or below the boundary.

  `archived` may be `nil`, and then those facts are derived from `preloaded`
  itself — the whole-sequence form that a caller holding the full list (a
  hand-built fixture, the recovery path) still gets.

  Bumps `state.chat_state.next_message_index` to one past the highest index
  in the *logical* sequence (`max(active, archived)`) so the next
  `__append_message__/2` doesn't stamp a colliding index. Reading it from the
  active slice alone is enough whenever that slice is non-empty, because
  every active index is above every archived one; the archived maximum
  matters only for a sequence whose active slice is empty.

  When the persisted sequence has no system row at all (a legacy
  pre-system-prompt row), defensively prepends the in-memory system message
  at index 0 and shifts the boundary up by 1 to keep the partition invariant
  (`active rows == rows above the boundary`).
  """
  @spec seed_from_db(
          Nest.Agents.Agent.t(),
          [Nest.Messages.Message.t()],
          integer(),
          non_neg_integer(),
          map() | nil
        ) :: Nest.Agents.Agent.t()
  def seed_from_db(
        state,
        preloaded,
        last_compaction_index,
        inherited_compaction_count \\ 0,
        archived \\ nil
      )

  # Nothing was loaded and nothing is archived: leave the fresh state alone,
  # which is the documented contract for a row-less agent. A `-1` boundary with
  # no rows is the common case here (every brand-new agent), and it must not
  # reach the prepend path below: there is no system row to *re*-establish, and
  # shifting a boundary that is already -1 would partition the in-memory
  # system row away.
  def seed_from_db(state, [], _last_compaction_index, _inherited_compaction_count, nil),
    do: state

  def seed_from_db(state, [], _last_compaction_index, _inherited_compaction_count, %{
        highest_index: highest
      })
      when highest < 0,
      do: state

  def seed_from_db(state, [], last_compaction_index, inherited_compaction_count, archived) do
    # An active slice can be empty while the archive is not: every row the
    # agent has may sit at or below its boundary. There is nothing to
    # partition, but the counters still have to clear the archive — an
    # `next_message_index` that did not would stamp an index the archive
    # already uses, and the unique `(agent_id, message_index)` index would
    # silently drop the append.
    seed_with_system_if_needed(
      state,
      [],
      last_compaction_index,
      inherited_compaction_count,
      archived
    )
  end

  def seed_from_db(state, preloaded, last_compaction_index, inherited_compaction_count, archived) do
    seed_with_system_if_needed(
      state,
      preloaded,
      last_compaction_index,
      inherited_compaction_count,
      archived
    )
  end

  @doc """
  Build the live state for a starting agent: the struct from attrs, then
  the persisted message sequence hydrated into it. No DB access, no
  broadcasts, no logging (see the hard rule in `Nest.Agents.Agent.init/1`).

  Both callers build state outside the child process: `init/1` (the happy
  path) and `Agent.PreSpawn.apply_load_heal/2`, which needs a state to run
  the load-time heal against before the child exists.
  """
  @spec build_active_state(map(), Nest.LLM.ClientConfig.t()) :: Nest.Agents.Agent.t()
  def build_active_state(attrs, client_config) do
    state = build_state(attrs, client_config)

    seed_from_db(
      state,
      Map.get(attrs, :preloaded_messages, []),
      Map.get(attrs, :last_compaction_index, -1),
      Map.get(attrs, :compaction_count, 0),
      Map.get(attrs, :archived_summary)
    )
  end

  # Whether the logical sequence carries a system row decides between
  # partitioning it as-is and the defensive prepend below. The system row may
  # sit in the archive — a compacted agent's prompt is at index 0, below the
  # boundary — so the active slice alone cannot answer it; `archived` carries
  # the answer for the rows that were not loaded. A clone inherits its
  # parent's system row the same way.
  defp seed_with_system_if_needed(state, preloaded, boundary, inherited_count, archived) do
    if has_system_row?(preloaded, archived) do
      do_seed(state, preloaded, boundary, inherited_count, archived)
    else
      prepend_system(state, preloaded, boundary, inherited_count, archived)
    end
  end

  defp has_system_row?(preloaded, nil), do: Enum.any?(preloaded, &match?({:system, _}, &1))

  defp has_system_row?(preloaded, archived) do
    archived.has_system_row or Enum.any?(preloaded, &match?({:system, _}, &1))
  end

  defp do_seed(state, [], last_compaction_index, inherited_count, archived) do
    # Every row is archived, so there is nothing to partition and the
    # in-memory system row stays where `build_state/2` put it. The counters
    # are still seeded, so a later append cannot collide with the archive.
    #
    # This is the exception to the partition invariant (`history ++ messages`
    # is the full sequence in order): the in-memory system row stays in the
    # active list while the archived copy stays in the archive, so index 0
    # lands in *both*. Dropping the in-memory row instead would leave an active
    # list with no system row, which the UI's "the active list always contains
    # at least its system row" invariant relies on. A reader that walks the
    # archive and the active list as one sequence has to expect the index to
    # repeat.
    state = put_counters(state, [], last_compaction_index, inherited_count, archived)
    put_crossed_thresholds(state)
  end

  defp do_seed(state, preloaded, last_compaction_index, inherited_count, archived) do
    messages =
      Enum.filter(preloaded, fn {_role, %{index: idx}} ->
        idx > last_compaction_index
      end)

    state = put_counters(state, preloaded, last_compaction_index, inherited_count, archived)
    state = %{state | chat_state: %{state.chat_state | messages: messages}}

    # Rebuild the announced context-threshold set from the persisted
    # notices in the active segment. Without this a BEAM restart would
    # reset `crossed_thresholds` and re-announce 25/50/75 on the next
    # turn. Archived notices (index <= the boundary) are excluded by the
    # `messages` partition, so a completed compaction still re-arms.
    put_crossed_thresholds(state)
  end

  # The counters the active slice cannot answer on its own: the compaction
  # count and the highest index of the *logical* sequence.
  #
  # The count has three sources, because no single one sees everything: the
  # active rows carry the markers above the boundary (none count, by the `<=`
  # rule), `inherited_count` carries what a clone's parent had at spawn, and
  # `archived` carries the markers that were read as a projection. A clone's
  # inherited markers live in the shared prefix, so they arrive through the
  # archive read rather than through its own rows.
  #
  # The highest index comes from the active slice whenever it has rows (every
  # active index is above every archived one), and from the archive when it
  # does not.
  defp put_counters(state, preloaded, last_compaction_index, inherited_count, archived) do
    compaction_count =
      preloaded
      |> count_markers(last_compaction_index)
      |> max(inherited_count)
      |> max(archived_marker_count(archived))

    highest_index = max(highest_index(preloaded), archived_highest_index(archived))

    %{
      state
      | chat_state: %{
          state.chat_state
          | last_compaction_index: last_compaction_index,
            compaction_count: compaction_count,
            next_message_index: highest_index + 1
        }
    }
  end

  defp count_markers(messages, last_compaction_index) do
    Enum.count(messages, fn
      {:compaction, %{index: idx}} -> idx <= last_compaction_index
      _ -> false
    end)
  end

  defp highest_index(messages) do
    messages
    |> Enum.map(fn {_role, %{index: idx}} -> idx end)
    |> Enum.max(fn -> -1 end)
  end

  defp archived_marker_count(nil), do: 0
  defp archived_marker_count(archived), do: archived.marker_count

  defp archived_highest_index(nil), do: -1
  defp archived_highest_index(archived), do: archived.highest_index

  # Stamp `live.crossed_thresholds` from the active message list (see
  # `ContextReminder.announced_thresholds/1`). Shared by both seed paths.
  defp put_crossed_thresholds(state) do
    crossed = ContextReminder.announced_thresholds(state.chat_state.messages)
    %{state | live: %{state.live | crossed_thresholds: crossed}}
  end

  # Defensive prepend: pre-existing rows may have messages
  # but no persisted system row. Shift the preloaded list
  # up by one and seed the in-memory system message at
  # position 0 so the system prompt survives BEAM restart.
  defp prepend_system(state, preloaded, last_compaction_index, inherited_count, archived) do
    [system | _] = state.chat_state.messages

    shifted =
      Enum.map(preloaded, fn {role, %{index: idx} = msg} ->
        {role, %{msg | index: idx + 1}}
      end)

    # After the prepend the system row sits at index 0, so
    # the partition needs to shift the boundary up by one as
    # well — the rows the caller persisted are now at their
    # original index + 1. Only the archived maximum moves with the shift
    # (a uniform renumber cannot change how many markers there are, and this
    # path is only reached when there is no system row anywhere).
    do_seed(
      state,
      [system | shifted],
      last_compaction_index + 1,
      inherited_count,
      shift_archived(archived)
    )
  end

  defp shift_archived(nil), do: nil

  defp shift_archived(%{highest_index: highest} = archived),
    do: %{archived | highest_index: highest + 1}

  @doc """
  Resolve the model's context limit by walking three layers,
  most-specific first.

  Used by `build_state/2` at init time, and by the compaction
  handler's `regenerate_for_compaction/2` to re-resolve after
  a Models-cache refresh or dotconfig reload.

  ## Layers

    1. Per-model static `context-limit` (in `[[providers.<name>.models]]`)
    2. Auto-discovery cache (`Nest.Models.context_limit/2`)
    3. Provider-wide `default-context-limit` on `[providers.<name>]`

  When none has a value, falls back to `{@default_limit, :default}` (a
  conservative 128k floor, matching `Nest.LLM.Discover`) so an agent
  always has a context limit rather than none at all.

  The resolutions are captured as 0-arity closures so each
  lookup only runs when the previous tier missed — calling
  `Nest.Models.context_limit/2` once costs a `GenServer.call`,
  and `DotConfig.load/0` reads + parses TOML.

  `cache_lookup` defaults to `Nest.Models.context_limit/2`. The
  `:context_limit_lookup` attr (read by `build_vocation_pipeline/1`)
  overrides the cache tier only, because that lookup runs inside the
  agent's `init/1` process — a supervisor child has no `$callers`
  chain back to the caller, so a caller-side stub is invisible there.
  """
  @spec initial_context_limit(
          map(),
          (String.t() | nil, String.t() | nil -> {atom(), pos_integer()} | nil)
        ) :: {non_neg_integer(), atom()}
  def initial_context_limit(model, cache_lookup \\ &Nest.Models.context_limit/2) do
    provider = model[:provider] || model["provider"]
    model_name = model_name(model)

    context_limit_layer(
      fn -> Config.configured_context_limit(model_name) end,
      fn -> cache_lookup.(provider, model_name) end,
      fn -> Config.configured_provider_default_context_limit(provider) end
    )
  end

  defp context_limit_layer(configured, cache, provider_default) do
    case configured.() do
      limit when is_integer(limit) ->
        {limit, :config}

      _ ->
        resolve_cache_or_default(cache, provider_default)
    end
  end

  defp resolve_cache_or_default(cache, provider_default) do
    case cache.() do
      {source, limit} when is_integer(limit) ->
        {limit, source}

      _ ->
        case provider_default.() do
          limit when is_integer(limit) -> {limit, :provider_default}
          _ -> {@default_limit, :default}
        end
    end
  end

  defp model_name(model), do: model[:name] || model["name"]

  defp initial_messages_with_system(system_prompt) do
    message =
      {:system,
       %System{
         index: 0,
         parts: [%Part.Text{text: system_prompt || ""}],
         timestamp: DateTime.utc_now(),
         api_logs: []
       }}

    {[message], 1}
  end

  defp build_llm_metrics(context_limit, source) do
    %Nest.Agents.Agent.LlmMetrics{
      context_limit: context_limit,
      context_limit_source: source,
      usage_totals: Broadcasts.empty_usage_totals(),
      # `descendant_usage` is initialized to a fresh totals map
      # (not `nil`) so the merge helpers don't need a nil
      # branch. Children merge into this field on completion;
      # the agent's `total_usage` is computed as
      # `usage_totals + descendant_usage`.
      descendant_usage: Broadcasts.empty_usage_totals()
    }
  end

  defp build_chat_state(messages, next_index, agent_row_id) do
    %Nest.Agents.Agent.ChatState{
      messages: messages,
      agent_row_id: agent_row_id,
      next_message_index: next_index
    }
  end

  # Per-process state always resets to defaults on init/1.
  defp build_live_state(mode) do
    %Nest.Agents.Agent.ChatState.Live{mode: mode}
  end

  defp create_tmp_space(space_id, agent_name, backend) do
    Nest.Agents.Agent.__create_tmp_space__(space_id, agent_name, backend)
  end
end
