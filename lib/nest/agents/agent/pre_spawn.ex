defmodule Nest.Agents.Agent.PreSpawn do
  @moduledoc """
  The pre-spawn phase: everything that must happen in the *caller's* pid
  before an agent process exists.

  `Nest.Agents.Agent.start_link/1` spawns the child, and the child's
  `init/1` must not touch the DB — the pid the supervisor spawns has no
  Ecto Sandbox `$callers` chain back to the connection owner (see the hard
  rule in `Nest.Agents.Agent.init/1`). So the row inserts, the initial
  system message and the load-time sequence heal all run here, in the
  caller's DB context, and the child is handed attrs it can build its
  in-memory state from.

  Extracted from `Nest.Agents.Agent` for the same reason as `Init`,
  `ClientAPI` and the `*Handler` modules: the GenServer module was at the
  source-file line cap. `Agent` re-exports the three entry points
  (`pre_spawn/1`, `pre_load_heal/1`, `build_child_attrs/5`) unchanged, so
  callers keep using them through the GenServer module.
  """

  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Persistence
  alias Nest.Sandbox.Mounts

  @doc """
  Pre-spawn DB work for `start_link/1`. Inserts the agent row
  and the initial system message in the *caller's* DB context
  (test pid for tests, channel pid for production) so the
  supervisor pid never has to do DB work during spawn.

  Returns `{:ok, id}` (the inserted row's `agents.id`) on success,
  `{:error, reason}` on failure, so a caller whose start then fails can
  remove *its own* row. On `:duplicate_name` nothing was inserted.
  """
  @spec pre_spawn(map()) :: {:ok, integer()} | {:error, term()}
  def pre_spawn(attrs) do
    case Map.get(attrs, :fork_message_index) do
      nil -> pre_spawn_with_system(attrs)
      fork_index -> pre_spawn_clone(attrs, fork_index)
    end
  end

  # Root and fresh-child path: own the system row at index 0.
  defp pre_spawn_with_system(attrs) do
    # Refuse an agent without a non-empty system message (validate first).
    case build_initial_system_message(attrs) do
      {:ok, system_message} ->
        with {:ok, %{id: id}} <- Persistence.insert_agent(attrs),
             {:ok, _} <- Persistence.insert_message(attrs.space_id, attrs.name, system_message) do
          {:ok, id}
        end

      {:error, :missing_system_prompt} ->
        {:error, :missing_system_prompt}
    end
  end

  # Clone path: persist only the rows the clone owns (indices at or
  # above its fork boundary). The shared prefix is inherited from the
  # ancestors and never duplicated (D1/D2), and index 0 belongs to the
  # root ancestor, so no system row is written (D5).
  defp pre_spawn_clone(attrs, fork_index) do
    own_messages =
      attrs
      |> Map.get(:preloaded_messages, [])
      |> Enum.filter(fn {_role, %{index: idx}} -> idx >= fork_index end)

    with {:ok, %{id: id}} <- Persistence.insert_agent(attrs),
         :ok <- persist_own_messages(attrs, own_messages) do
      {:ok, id}
    end
  end

  defp persist_own_messages(attrs, messages) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case Persistence.insert_message(attrs.space_id, attrs.name, message) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Render the system prompt in the calling process (so the DB write
  # runs in a pid with DB access); `nil` only when the vocation is missing.
  defp build_initial_system_message(attrs) do
    name = Map.fetch!(attrs, :name)
    model = Map.fetch!(attrs, :model)
    vocation = Map.get(attrs, :vocation)
    depth = Map.get(attrs, :depth, 0)

    {context_limit, context_limit_source} = Init.initial_context_limit(model)

    {system_prompt, _mode, _tools, _cached_vocation} =
      SystemPrompt.compose_vocation_config(
        vocation,
        Mounts.new(Map.get(attrs, :workspace_path), nil),
        {context_limit, context_limit_source},
        name,
        depth
      )

    case system_prompt do
      text when is_binary(text) and text != "" ->
        {:ok,
         {:system,
          %System{
            index: 0,
            parts: [%Part.Text{text: text}],
            timestamp: DateTime.utc_now(),
            api_logs: []
          }}}

      _ ->
        {:error, :missing_system_prompt}
    end
  end

  @doc """
  Apply the load-time sequence heal in the *caller's* DB context.

  `Persistence.build_attrs_for_start/2` classifies the restored active
  slice and puts the heal in `:load_heal` — a trailing orphan
  `tool_use` (a turn that died mid-tool), the user-tail bridge, or the
  lost-promise record for a backgrounded call whose batch died with the
  process (see `Init.LoadHeal`). Applying it appends and persists real rows
  through the canonical append path, so it MUST run in a pid with DB access:
  the caller's, before `GenServer.start_link/1`. It must never run in `init/1`
  (see the hard rule there).

  Idempotent: the classification is re-derived from a fresh read
  immediately before the append (`Init.LoadHeal.refresh/1`), so a caller
  that raced another one for the same tail appends nothing.

  Returns `attrs` with the healed rows folded into `:preloaded_messages`
  and `:load_heal` cleared, so the child only has to seed from attrs. A
  caller whose tail is already healed gets
  the freshly-read attrs back instead (nothing appended), and `attrs`
  unchanged when the agent row is gone or the model no longer resolves —
  the latter boots `init/1` in `:model_missing`, matching the
  pre-refactor behavior.
  """
  @spec pre_load_heal(map()) :: map()
  def pre_load_heal(attrs) do
    case Map.get(attrs, :load_heal) do
      nil -> attrs
      _heal -> heal_if_still_needed(attrs)
    end
  end

  # Idempotent heal: `Init.LoadHeal.refresh/1` re-derives the
  # classification from a fresh read, so a caller that lost a race for the
  # same tail sees `load_heal: nil` and starts its child from the freshly
  # read rows instead of appending a second heal. See that function for why
  # the re-check is preferred over serialization.
  defp heal_if_still_needed(attrs) do
    case Init.LoadHeal.refresh(attrs) do
      nil -> attrs
      %{load_heal: nil} = fresh -> fresh
      %{load_heal: heal} = fresh -> apply_load_heal(fresh, heal)
    end
  end

  defp apply_load_heal(attrs, heal) do
    case Config.create_client_config(Map.fetch!(attrs, :model)) do
      {:ok, client_config} ->
        state = Init.build_active_state(attrs, client_config)
        healed = Init.LoadHeal.heal(state, heal)
        healed_attrs(attrs, state, healed)

      {:error, _reason} ->
        attrs
    end
  end

  # Fold the rows the heal appended (already persisted by the append
  # path) into the attrs the child seeds from, so `init/1` reconstructs
  # the healed sequence without any DB work of its own. The index is not
  # carried here: `Init.seed_from_db/5` recomputes `highest_index + 1`
  # from `:preloaded_messages` and `:archived_summary` (the highest index
  # can come from either), and `Persistence.insert_agent/1` (the
  # only reader of an attrs `:next_message_index`) only ever runs for a
  # brand-new agent via `pre_spawn/1`.
  defp healed_attrs(attrs, before, healed) do
    appended = Enum.drop(healed.chat_state.messages, length(before.chat_state.messages))

    attrs
    |> Map.put(:preloaded_messages, Map.get(attrs, :preloaded_messages, []) ++ appended)
    |> Map.put(:load_heal, nil)
  end

  @doc """
  Build a child agent's attrs from a parent state and the
  clone instruction. Pure data shaping — no DB writes, no
  spawning.

  The caller (the supervisor's `start_agent_with_parent/2`)
  provides:
    * `child_name` — a freshly-generated unique name
    * `parent_id` — the parent's integer `agents.id`,
      resolved via `Persistence.fetch_agent/2`
    * `model_override` — an optional `%{name: ..., provider: ...}`
      map for the child's model; the child inherits the parent's
      model when it is `nil`

  Returns the attrs map ready to pass to `start_link/1`.
  """
  @spec build_child_attrs(map(), String.t(), String.t(), integer(), map() | nil) :: map()
  def build_child_attrs(parent_state, instruction, child_name, parent_id, model_override \\ nil)
      when is_map(parent_state) and is_binary(instruction) and is_binary(child_name) do
    # The clone starts from the parent LLM-facing context: the visible
    # `messages` only. The archived slice is not part of any context - it is
    # derived on demand (`Persistence.load_history/2`) and it contains the
    # non-LLM-visible `{:compaction, _}` marker row, which is exactly how a
    # marker used to end up in a child context.
    shared_prefix = parent_state.chat_state.messages
    fork_index = parent_state.chat_state.next_message_index

    {preloaded, next_index} =
      MessageList.build_clone_fork(shared_prefix, fork_index, child_name, parent_state.depth + 1)

    %{
      name: child_name,
      space_id: parent_state.space_id,
      model: model_override || parent_state.model,
      vocation_id: parent_state.vocation_id,
      vocation: parent_state.vocation,
      workspace_path: parent_state.workspace_path,
      parent_id: parent_id,
      parent_name: parent_state.name,
      # Children inherit the parent's user identity and
      # visibility — a private agent always spawns private
      # children, and a shared parent may spawn shared
      # children. The child can be flipped later via an
      # edit flow (currently the new-agent form is the only
      # place to set `shared`).
      created_by_user_id: parent_state.created_by_user_id,
      shared: parent_state.shared,
      depth: parent_state.depth + 1,
      # `nil` for a fresh child (owns from 0); the first owned
      # index for a clone (shares everything below it).
      fork_message_index: fork_index,
      preloaded_messages: preloaded,
      # The child inherits the shared sequence boundary: below `F`
      # belong to ancestors, and the partition must file the ancestor
      # marker (and everything it archived) as archived here too.
      last_compaction_index: Map.get(parent_state.chat_state, :last_compaction_index, -1),
      compaction_count: Map.get(parent_state.chat_state, :compaction_count, 0),
      next_message_index: next_index
    }
  end
end
