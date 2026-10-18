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
  alias Nest.Agents.Agent.ModeAuthority
  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.PersistedAgent
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Persistence
  alias Nest.Repo
  alias Nest.Sandbox.Mounts

  @doc """
  Pre-spawn work for `start_link/1`: the one gate every agent-creation path
  goes through, then the DB work. Inserts the agent row
  and the initial system message in the *caller's* DB context
  (test pid for tests, channel pid for production) so the
  supervisor pid never has to do DB work during spawn.

  The gate is the `"none"`-space scratch-name rule: such a space's agents live
  at `/tmp/<name>` in the host's one `/tmp`, so a name another `"none"` space's
  live agent holds is refused with `{:error, {:scratch_name_in_use, name}}`,
  and a name nobody holds has its stale directory cleared. Both are described
  where they are implemented.

  Returns `{:ok, id}` (the inserted row's `agents.id`) on success,
  `{:error, reason}` on failure, so a caller whose start then fails can
  remove *its own* row. On `:duplicate_name` nothing was inserted.
  """
  @spec pre_spawn(map()) :: {:ok, integer()} | {:error, term()}
  def pre_spawn(attrs) do
    # The space's environment — backend, network access and workspace — is
    # resolved here, at the one gate every creation path goes through, so a
    # caller that built its attrs from a parent's mounts cannot hand a child a
    # stale copy. `Nest.Agents.Agent.Init` reads all three off the attrs and must
    # never touch the DB.
    attrs = Persistence.put_space_properties(attrs)

    with :ok <- ensure_scratch_name(attrs),
         {:ok, attrs} <- put_mode(attrs) do
      case Map.get(attrs, :fork_message_index) do
        nil -> pre_spawn_with_system(attrs)
        fork_index -> pre_spawn_clone(attrs, fork_index)
      end
    end
  end

  # The mode a new agent starts in, decided once, here, because this is the one
  # gate every creation path goes through (`pre_spawn/1`'s moduledoc): a
  # caller-created agent, a clone and a fresh sub-agent all arrive here.
  #
  #   * a caller that named a mode keeps it, but only if the authority allows it
  #     — a `plan` parent may not spawn an `act` child, and may not spawn one and
  #     then raise it (`Nest.Agents.Agent.ModeAuthority`);
  #   * otherwise a child **inherits its parent's current mode**, so the child of
  #     a read-only agent is read-only;
  #   * otherwise — a root agent — it gets the mode the space's blueprint names.
  #
  # The derived value goes back into the attrs, which is what makes it the row's:
  # `Persistence.insert_agent/1` writes it, and a restart reads it back, so the
  # mode survives a restart instead of being re-derived from a default.
  defp put_mode(attrs) do
    case Map.get(attrs, :mode) do
      # `"mine"` is the send tools' spelling for "the sender's own mode", and for
      # a spawn that is exactly the inherited one: `agents-batch` takes `set_mode`
      # with that enum, and every child of a batch is a spawn. It is a spelling,
      # not a shortcut — it resolves to a mode and then goes through the same
      # authority as any other request, because *who is asking* is the whole rule.
      "mine" -> authorize_mode(attrs, inherited_mode(attrs))
      # A blank counts as unnamed: a client that sends `""` gets the inherited
      # mode rather than a refusal for a mode called "".
      mode when is_binary(mode) and mode != "" -> authorize_mode(attrs, mode)
      _other -> {:ok, Map.put(attrs, :mode, inherited_mode(attrs))}
    end
  end

  @doc false
  # The mode a spawner named, if it named one. A blank counts as unnamed, and so
  # does anything that is not a binary, so `put_mode/1` derives the mode exactly
  # as it does when a spawn names none.
  #
  # Public because the two attrs builders that feed `pre_spawn/1` live in
  # different modules (`SubAgent.build_fresh_child_attrs/7` for a fresh child and
  # `build_child_attrs/6` for a clone) and must agree about what "named" means.
  @spec put_named_mode(map(), term()) :: map()
  def put_named_mode(attrs, mode) when is_binary(mode) and mode != "",
    do: Map.put(attrs, :mode, mode)

  def put_named_mode(attrs, _mode), do: attrs

  defp authorize_mode(attrs, mode) do
    case ModeAuthority.authorize(actor(attrs), mode) do
      :ok -> {:ok, Map.put(attrs, :mode, mode)}
      {:error, reason} -> {:error, {:mode_refused, reason}}
    end
  end

  # The actor is the parent when there is one — a spawn *is* the parent acting —
  # and the human otherwise, because a root agent is created by a person (from
  # the UI, or from a test), and the human is above the rule.
  defp actor(attrs) do
    case parent_row(attrs) do
      %PersistedAgent{name: name, mode: mode} ->
        %{kind: :agent, space_id: attrs.space_id, name: name, mode: mode, target: :child}

      _no_parent ->
        %{kind: :human}
    end
  end

  defp inherited_mode(attrs) do
    case parent_row(attrs) do
      %PersistedAgent{mode: mode} when is_binary(mode) -> mode
      _no_parent -> blueprint_default_mode(attrs.space_id)
    end
  end

  # The parent's *row*, from whichever identifier the attrs carry: a spawn passes
  # `parent_id` (the `agents.id`), and the restart path passes `parent_name` too.
  # The row is the truth about the parent's mode — it is what the parent's own
  # next turn runs under — so it is read here rather than taken from anything the
  # caller remembered.
  defp parent_row(%{parent_name: name, space_id: space_id})
       when is_binary(name) and is_integer(space_id) do
    case Persistence.fetch_agent(space_id, name) do
      {:ok, row} -> row
      _other -> nil
    end
  end

  defp parent_row(%{parent_id: id}) when is_integer(id), do: Repo.get(PersistedAgent, id)
  defp parent_row(_attrs), do: nil

  # A root agent's mode is the one the space's blueprint names. A space with no
  # blueprint (or one from before blueprints had a default) falls back to the
  # permissive default, which is what every agent had before a mode was a
  # per-agent property.
  defp blueprint_default_mode(space_id) do
    with %{blueprint_id: id} when is_integer(id) <- Nest.Spaces.get_space(space_id),
         %{default_mode: mode} when is_binary(mode) <- Nest.Blueprints.get_blueprint(id) do
      mode
    else
      _other -> Nest.Modes.default()
    end
  end

  # The one gate every agent-creation path goes through — a caller-created
  # agent (`Nest.Agents.create_agent/3`), a clone
  # (`Supervisor.start_agent_with_parent/3`) and a fresh sub-agent
  # (`Supervisor.spawn_agent_in_space/4`) all reach `pre_spawn/1` and nothing
  # else does. That makes this the right place for the one name rule that is
  # about a *directory* rather than a row, and the last point before the row is
  # written.
  #
  # Only a `"none"` space has the rule: it runs on the host, so its agents'
  # scratch directories are `/tmp/<name>` in the host's one `/tmp`
  # (`Nest.Agents.Agent.TmpSpace`), and two `"none"` spaces therefore share a
  # single namespace of names. Every other backend gives each space its own
  # root, where the same name is two different directories and no rule is
  # needed.
  defp ensure_scratch_name(attrs) do
    name = Map.fetch!(attrs, :name)

    # A name that is not a single safe path component is the row changeset's
    # refusal to make (`PersistedAgent.valid_name?/1`), and it has no path to
    # collide on — so this gate leaves it alone rather than raising on a name
    # `TmpSpace.agent_dir/3` would refuse to turn into a path.
    if PersistedAgent.valid_name?(name) and none_space?(attrs) do
      none_space_scratch_name(Map.fetch!(attrs, :space_id), name)
    else
      :ok
    end
  end

  # The backend is already on the attrs — every caller resolves it from the space
  # row before `pre_spawn/1` (see `Persistence.build_agent_attrs/1` and
  # `start_attrs/7`), and `Init` reads the same key a few lines later. Reading the
  # row again here would be a second query per agent creation for a value the
  # caller already has.
  defp none_space?(attrs), do: Map.fetch!(attrs, :sandbox_backend) == "none"

  defp none_space_scratch_name(space_id, name) do
    case other_none_space_holder(space_id, name) do
      nil -> clear_stale_scratch(space_id, name)
      other_space_id -> {:error, {:scratch_name_in_use, space_label(other_space_id)}}
    end
  end

  # No live agent holds the name, so whatever sits at the path is a stopped
  # agent's leftovers — *if* it is Nest's at all. `/tmp/<name>` is the host's own
  # `/tmp` and the name is client- and model-controlled, so a directory Nest did
  # not put there is refused by name rather than adopted: `TmpSpace.create/3`
  # would otherwise stamp its marker into it and hand the next `cleanup/3` a
  # licence to delete it (`nest-4` is another BEAM's whole scratch root, and
  # `X11-unix` and `snap-private-tmp` are real `/tmp` entries).
  #
  # The refusal belongs here, at the point the name is chosen, rather than as a
  # raise from `init/1` that the start path rolls back: the caller can then say
  # which name to pick instead.
  #
  # Refusing here is also safe against a live holder: this runs in the caller,
  # before `start_link/1` registers the name, so a live one would have been found
  # above.
  defp clear_stale_scratch(space_id, name) do
    path = TmpSpace.agent_dir(space_id, name, "none")

    if TmpSpace.claimable?(path, "none") do
      TmpSpace.remove_stale(space_id, name, "none")
    else
      {:error, {:scratch_path_taken, path}}
    end
  end

  defp other_none_space_holder(space_id, name) do
    none_ids = Nest.Spaces.none_space_ids()

    Nest.Agents.Registry.list_all()
    |> Enum.find_value(fn {other_space_id, other_name} ->
      other_name == name and other_space_id != space_id and
        MapSet.member?(none_ids, other_space_id) and other_space_id
    end)
  end

  # The other space's name, for the message the user reads. It must exist — a
  # live agent is registered under it — but a race with a delete would leave
  # nothing to look up, so fall back to something that still names it.
  defp space_label(space_id) do
    case Nest.Spaces.get_space(space_id) do
      %{name: name} when is_binary(name) -> name
      _ -> "space ##{space_id}"
    end
  end

  # Root and fresh-child path: own the system row at index 0.
  defp pre_spawn_with_system(attrs) do
    # Compose the system prompt here, in the caller, and carry it on the attrs so
    # `init/1` reuses it. Composing it reads `AGENTS.md` and `.nest` from disk,
    # and `init/1` runs with the supervisor blocked until it returns — so
    # composing it there was serial across every agent start. Only this path
    # needs it: the clone path writes no system row. See `Init.prepare/1`.
    attrs = Init.prepare(attrs)

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

  # Wrap the prompt `Init.prepare/1` composed — in this same process, so the DB
  # write runs in a pid with DB access — in the index-0 system message. An empty
  # or missing prompt is `{:error, :missing_system_prompt}`.
  defp build_initial_system_message(attrs) do
    case initial_system_prompt(attrs) do
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

  # The prompt this agent will run with, composed by `Init.prepare/1` in this
  # same process before the row is written. There is deliberately no fallback
  # composer here: every path into `pre_spawn_with_system/1` has been through
  # `Init.prepare/1` (see `pre_spawn/1`), and a second copy of the
  # `(vocation, mounts, context_limit_info, name, depth, mode)` argument list is
  # exactly the transposition hazard the composer's call site documents.
  defp initial_system_prompt(attrs) do
    case Map.get(attrs, :prepared) do
      {system_prompt, _mode, _tools, _vocation, _metrics} ->
        system_prompt

      nil ->
        raise ArgumentError,
              "PreSpawn.pre_spawn/1 requires attrs that Init.prepare/1 could prepare " <>
                "(name, space_id, sandbox_backend, network_access, model); " <>
                "got #{inspect(Map.keys(attrs))}"
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
  @spec build_child_attrs(map(), String.t(), String.t(), integer(), map() | nil, String.t() | nil) ::
          map()
  def build_child_attrs(
        parent_state,
        instruction,
        child_name,
        parent_id,
        model_override \\ nil,
        mode \\ nil
      )
      when is_map(parent_state) and is_binary(instruction) and is_binary(child_name) do
    Map.merge(
      inherited_attrs(parent_state, child_name, parent_id, model_override),
      fork_attrs(parent_state, child_name)
    )
    |> put_named_mode(mode)
  end

  # Everything a clone takes from its parent: identity, space, model, vocation,
  # the space-level properties it shares (sandbox backend, network access), and
  # the parent's user identity and visibility — a private agent always spawns
  # private children, and a shared parent may spawn shared children.
  defp inherited_attrs(parent_state, child_name, parent_id, model_override) do
    %{
      name: child_name,
      space_id: parent_state.space_id,
      model: model_override || parent_state.model,
      vocation_id: parent_state.vocation_id,
      vocation: parent_state.vocation,
      sandbox_backend: Mounts.backend(parent_state.mounts),
      network_access: Mounts.network_access(parent_state.mounts),
      parent_id: parent_id,
      parent_name: parent_state.name,
      created_by_user_id: parent_state.created_by_user_id,
      shared: parent_state.shared,
      depth: parent_state.depth + 1
    }
  end

  # The fork's sequence boundary: `nil` for a fresh child (owns from 0), the
  # first owned index for a clone (shares everything below it). The child also
  # inherits the shared boundary — below `F` belong to ancestors, and the
  # partition must file the ancestor marker (and everything it archived) as
  # archived here too.
  defp fork_attrs(parent_state, child_name) do
    {fork_index, preloaded, next_index} = clone_fork(parent_state, child_name)

    %{
      fork_message_index: fork_index,
      preloaded_messages: preloaded,
      last_compaction_index: Map.get(parent_state.chat_state, :last_compaction_index, -1),
      compaction_count: Map.get(parent_state.chat_state, :compaction_count, 0),
      next_message_index: next_index
    }
  end

  # The clone's forked message prefix and the index it owns from. Extracted from
  # `build_child_attrs/5` to keep that function's ABC size down.
  #
  # The clone starts from the parent LLM-facing context: the visible `messages`
  # only. The archived slice is not part of any context - it is derived on
  # demand (`Persistence.load_history/2`) and it contains the non-LLM-visible
  # `{:compaction, _}` marker row, which is exactly how a marker used to end up
  # in a child context.
  defp clone_fork(parent_state, child_name) do
    fork_index = parent_state.chat_state.next_message_index

    {preloaded, next_index} =
      MessageList.build_clone_fork(
        parent_state.chat_state.messages,
        fork_index,
        child_name,
        parent_state.depth + 1
      )

    {fork_index, preloaded, next_index}
  end
end
