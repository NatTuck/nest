defmodule Nest.Agents.Agent.IntrospectionHandler do
  @moduledoc """
  `handle_call/3` clauses for the agent's introspection
  interface — `:get_*` calls used by tests, the supervisor,
  and the channel wrapper to read state without round-tripping
  through the channel layer.

  Extracted from `Nest.Agents.Agent` to keep that module under
  the credo 500-line cap.

  Each clause is a one-liner that reads a field from
  `state.chat_state` and returns it. The `:get_public_info`
  clause assembles the full public info map (cached Vocation
  + current state + usage totals) in one shot for the channel
  wrapper's `:get_public_info` GenServer call.

  The `:set_consecutive_compaction_count/2` and
  `:get_consecutive_compaction_count/0` clauses are test-only
  hooks for the loop-breaker counter. Production callers
  should not need them — the counter is managed internally
  by `Machine.Compaction.stage/3` (the `loop_count` loop-breaker) and
  resets via the append_message path in the agent's `handle_call/3`.

  The `:check_read_policy/2` clause is the synchronous
  pre-call gate used by `BatchSizer.execute_one/2` (in a
  worker task) before any `file-write` runs. It looks up
  `state.chat_state.read_files[path]` and either returns
  `:ok`, `{:error, :never_read}`, or
  `{:error, :contents_changed}` based on whether the cache
  holds a fresh `{mtime, size}` pair for the path. The
  worker translates the failure atom into a synthetic
  `ToolResult{is_error: true, content: <reason>}` so the
  LLM sees a structured refusal and can retry.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Inbox
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.ModelHandler
  alias Nest.Agents.Agent.Restore
  alias Nest.Agents.Agent.WorkspaceHandler
  alias Nest.LLM.Client
  alias Nest.Messages.Message
  alias Nest.Messages.Streaming
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts
  alias Nest.Vocations

  @doc """
  Dispatch an introspection `handle_call/3` message. Returns
  the GenServer's reply tuple.
  """
  @spec handle(term(), GenServer.from(), Agent.t()) :: GenServer.reply()
  def handle({:set_consecutive_compaction_count, n}, _from, state) when is_integer(n) do
    {:reply, :ok, %{state | live: %{state.live | machine: %{state.live.machine | loop_count: n}}}}
  end

  def handle(:get_consecutive_compaction_count, _from, state) do
    {:reply, state.live.machine.loop_count, state}
  end

  # Test-harness lifecycle (issue #21): the teardown's status question. It is
  # answered *here*, in this process, from this process's own machine, so the
  # caller never samples a state the agent has already left behind — and a
  # caller that gets no answer learns only that this process was not there to
  # give one (already gone, or already dying), never that it was busy.
  #
  # A turn runs in a worker task, never in this loop, so a genuinely mid-turn
  # agent answers with `:streaming`/`:executing_tools`/`:compacting`: the status
  # *value* is the in-flight signal, not a failure to answer.
  def handle(:get_status, _from, state) do
    {:reply, Machine.status_for(state.live.machine), state}
  end

  def handle(:get_public_info, _from, state) do
    build_public_info(state)
  end

  def handle(:get_messages, _from, state) do
    {:reply, state.chat_state.messages, state}
  end

  # Returns `{messages, cancelled}` so the turn can
  # short-circuit on user-initiated stops without waiting
  # for the next `:stop_chat` message to be processed.
  def handle(:get_messages_with_cancelled, _from, state) do
    {:reply, {state.chat_state.messages, state.live.cancelled}, state}
  end

  # Fetch the API logs for a specific message.
  #
  # Response logs live on the message (assistant/system messages are
  # persisted with their real response log). User/tool messages never
  # carry stored request logs — their request log is synthetic and is
  # rebuilt on demand here.
  def handle({:get_api_logs, index, history}, _from, state) do
    {:reply, api_logs_for(state, index, history), state}
  end

  def handle(:get_crossed_thresholds, _from, state) do
    {:reply, state.live.crossed_thresholds, state}
  end

  # The raw children sub-machine (`Machine.Children`): the per-child entry
  # map `Children.target/2` needs. `:get_pending_children` does not serve
  # it — that narrows to the `:running` names, which is a different value.
  def handle(:get_children, _from, state) do
    {:reply, state.live.machine.children, state}
  end

  # The machine's turn-scoped working set (`Machine.Work`): the active
  # worker/ref, the backgrounded batches, the compaction focus. Read as
  # one value so a caller that inspects several of its fields sees one
  # snapshot rather than one per field.
  def handle(:get_work, _from, state) do
    {:reply, state.live.machine.work, state}
  end

  # The LLM client configuration: the client module plus the per-call
  # opts. Deliberately not a `get_public_info/1` field — `client` is an
  # internal module atom the UI has no use for.
  def handle(:get_client_config, _from, state) do
    {:reply, state.client_config, state}
  end

  # The registered tool closures. Test-only by construction: a closure
  # cannot be serialized, so this can never be a wire field.
  def handle(:get_tools, _from, state) do
    {:reply, state.tools, state}
  end

  # The cached Vocation struct (see `build_public_info/1` for why the
  # runtime never broadcasts it).
  def handle(:get_vocation, _from, state) do
    {:reply, state.vocation, state}
  end

  # The outstanding watch registrations (issue #54), keyed by the
  # watcher's ref: `%{pid: pid | nil, spec: term(), satisfied: boolean}`.
  def handle(:get_watches, _from, state) do
    {:reply, state.live.watches, state}
  end

  def handle(:get_next_index, _from, state) do
    {:reply, state.chat_state.next_message_index, state}
  end

  # Test-only introspection: returns the assembled system
  # prompt (the content of the `{:system, _}` message at
  # position 0 of `state.chat_state.messages`).
  def handle(:get_system_prompt, _from, state) do
    {:reply, system_prompt_from_messages(state.chat_state.messages), state}
  end

  # Test-friendly: returns the running-children map (name => waiting
  # caller pid — the blocking tool worker, or the async waiter it
  # started) so a test can assert which callers are currently parked on
  # an `agents-spawn` (with `query`) tool call. The bookkeeping lives in
  # the machine's `Children` sub-machine. Production code should use
  # `:get_total_usage` / `get_public_info` instead.
  def handle(:get_pending_children, _from, state) do
    {:reply, Machine.pending_children(state.live.machine), state}
  end

  def handle(:get_total_usage, _from, state) do
    {:reply,
     Broadcasts.total_usage(state.llm_metrics.usage_totals, state.llm_metrics.descendant_usage),
     state}
  end

  # Pre-call gate for `file-write`. Looks up the cache entry
  # for `path`; if absent → the agent has not yet called
  # `file-read` (or the path has been cleared by a post-
  # compaction reset). If present, re-stat the file at the
  # full path; the on-disk mtime/size must equal the recorded
  # pair — otherwise the file has been modified since the
  # read or since the last `file-write`. Both error cases map
  # to a stable atom (`:never_read` / `:contents_changed`)
  # the worker translates to user-facing strings.
  #
  # Path resolution mirrors the read-tracking write at
  # `LLMStreamHandler` so the cache keys match the lookup
  # keys. Both treat absolute paths as-is and join relative
  # ones onto the per-agent workspace root.
  def handle({:check_read_policy, %{path: path}}, _from, state) do
    {:reply, check_read_policy(path, state), state}
  end

  # Test-only: returns the raw `read_files` map so tests can
  # assert what was tracked after a sequence of tool calls
  # without round-tripping through tool-result inspection.
  def handle(:get_read_files, _from, state) do
    {:reply, state.chat_state.read_files, state}
  end

  # Forward `{:set_model, _}` to the dedicated handler in
  # `ModelHandler`. Lives in a separate file so the
  # validation/persist/mutate/broadcast sequence can stay
  # together without inflating this module past the credo
  # 500-line cap.
  def handle({:set_model, _new_model} = msg, from, state) do
    ModelHandler.handle(msg, from, state)
  end

  # Forward `{:edit_agent, _, _}` (combined model + workspace edit)
  # and `{:set_workspace, _}` (standalone workspace change) to
  # `ModelHandler` / `WorkspaceHandler`.
  def handle({:edit_agent, _, _} = msg, from, state) do
    ModelHandler.handle(msg, from, state)
  end

  def handle({:set_workspace, _path} = msg, from, state) do
    WorkspaceHandler.handle(msg, from, state)
  end

  # Pre-call gate for `file-write`. Looks up the cache entry
  # for `path`; if absent → the agent has not yet called
  # `file-read` (or the path has been cleared by a post-
  # compaction reset). If present, re-stat the file at the
  # full path; the on-disk mtime/size must equal the recorded
  # pair — otherwise the file has been modified since the
  # read or since the last `file-write`. Both error cases map
  # to a stable atom (`:never_read` / `:contents_changed`)
  # the worker translates to user-facing strings.
  #
  # Path resolution mirrors the read-tracking write at
  # `LLMStreamHandler` so the cache keys match the lookup
  # keys. Both treat absolute paths as-is and join relative
  # ones onto the per-agent workspace root.
  # Fetch the API logs for a specific message. Response logs live on
  # the message (assistant/system messages are persisted with their real
  # response log). User/tool messages never carry a stored request log —
  # theirs is synthetic and rebuilt on demand here.
  defp api_logs_for(state, index, history) do
    messages = history ++ state.chat_state.messages

    case find_message(messages, index) do
      nil ->
        {:error, :not_found}

      {_role, %{api_logs: logs}} when is_list(logs) and logs != [] ->
        {:ok, Message.format_api_logs(logs)}

      {role, %{index: idx}} when role in [:user, :tool] ->
        {:ok, rebuild_request_logs(state, messages, idx)}

      _message ->
        {:error, :no_logs}
    end
  end

  defp rebuild_request_logs(state, messages, idx) do
    preloaded = Enum.reject(messages, &match?({:compaction, _}, &1))

    api_log = Restore.rebuild_request_api_logs(state, preloaded, idx, state.client_config)

    Message.format_api_logs([api_log])
  end

  # Use the cached Vocation struct from state — no DB work
  # in the handler. The struct was loaded by the calling
  # process and passed into init/1 via `:vocation` in attrs.
  defp build_public_info(state) do
    public_info =
      %{
        name: state.name,
        space_id: state.space_id,
        model: state.model,
        workspace_path: state.workspace_path,
        message_count: length(state.chat_state.messages),
        # The two numbers the collapsed history card renders: where the
        # active messages start, and how many compactions have happened.
        # Both are O(1) state - the archive itself is never loaded for
        # this (see `Nest.Persistence.History`).
        last_compaction_index: state.chat_state.last_compaction_index,
        compaction_count: state.chat_state.compaction_count,
        status: Machine.status_for(state.live.machine),
        # Populated only in the `:needs_repair` state: the active
        # sequence's wire violations and the offline repair command the
        # UI banner shows. Empty/nil for a healthy agent.
        sequence_violations: state.live.repair.violations,
        repair_command: state.live.repair.command,
        vocation_id: state.vocation_id,
        vocation_slug: state.vocation && state.vocation.slug,
        # The agent's scratch directory, unconsumed by the client: `statusExtras/1`
        # in `assets/js/channels/agent.js` whitelists the fields it wants and
        # does not include this one, and no tool reads it either. Retained
        # because `agent_tmp_path_test.exs` uses it as its handle on the real
        # tmp lifecycle; removing it is issue #79.
        tmp_path: state.tmp_path,
        # Run the streaming accumulator (or nil) through
        # `Streaming.to_json_safe/1` so `get_public_info/1`
        # is JSON-encodable end-to-end. Lobby and AgentChannel
        # both consume this map and Phoenix.Channel.push/3
        # encodes it as JSON before the WS frame hits the wire;
        # a raw `%AssistantAccumulator{}` struct trips
        # `Protocol.UndefinedError` at `Jason.encode/1` time.
        partial: Streaming.to_json_safe(state.live.streaming_acc),
        modes: Vocations.list_modes(state.vocation),
        default_mode: Vocations.default_mode(state.vocation),
        current_mode: state.live.mode,
        context_limit: state.llm_metrics.context_limit,
        context_limit_source: state.llm_metrics.context_limit_source,
        # Sub-agent identity: the integer `agents.id` of the
        # agent that spawned this one (nil for roots), plus
        # the parent's readable name (so the UI's "back to
        # parent" link can navigate without an extra lookup),
        # plus the depth (0 for roots).
        parent_id: state.tree_position.parent_id,
        parent_name: state.tree_position.parent_name,
        depth: state.depth,
        # Multi-user identity. Exposed so the lobby can render
        # ownership + visibility badges without an extra DB
        # round-trip and so the agent channel can enforce
        # edit/delete rules on the basis of the same numbers.
        created_by_user_id: state.created_by_user_id,
        shared: state.shared
      }
      |> Map.merge(runtime_fields(state))

    {:reply, public_info, state}
  end

  # The per-broadcast derived fields (async inbox + usage). Split from
  # `build_public_info/1` to keep both under the credo ABC cap.
  defp runtime_fields(state) do
    %{
      # Queued async agent-to-agent messages (`agents-send`): the full
      # list for the UI viewer plus a count. See `Inbox`.
      pending_messages: Inbox.serialize(state.live.inbox),
      pending_message_count: length(state.live.inbox),
      # The peers this agent still owes a reply to (issue #31 §1.8): the
      # debtors, sorted, `[]` when nothing is owed — never nil and never
      # absent, so a client cannot mistake "not serialized" for "no debt".
      owed_replies: Machine.owed_senders(state.live.machine),
      # Direct usage (this agent's own LLM calls), plus the
      # context-window fields the chip needs (see
      # `Broadcasts.Usage.context_usage_map/4`).
      usage:
        Broadcasts.Usage.context_usage_map(
          state.llm_metrics.usage_totals,
          state.chat_state.messages,
          state.llm_metrics.context_limit,
          state.live.context_projection
        ),
      # Cumulative usage from all descendants.
      descendant_usage: state.llm_metrics.descendant_usage,
      # `direct + descendant`, computed field-by-field.
      total_usage:
        Broadcasts.total_usage(
          state.llm_metrics.usage_totals,
          state.llm_metrics.descendant_usage
        )
    }
  end

  defp system_prompt_from_messages([{:system, %{parts: parts}} | _]) when is_list(parts) do
    Client.text_from_parts(parts)
  end

  defp system_prompt_from_messages(_), do: nil

  defp find_message(messages, idx) do
    Enum.find(messages, fn
      {_, %{index: i}} -> i == idx
      _ -> false
    end)
  end

  # Three-step pipeline (resolve path → stat the on-disk file
  # → match against the cache) split into flat helpers. The
  # `cond`/`case` nesting in a single function tripped credo's
  # "max depth 2" rule; this version is `2 + 1 + 1`.
  #
  # No-path is a `BatchSizer` defensive fallback (the
  # `BatchSizer.FilePolicy.check/2` call only fires for
  # `file-write` tool calls, and only those carry a `path`
  # argument). A non-binary `raw_path` short-circuits to
  # `:ok` so the worker doesn't refuse legitimate calls
  # where `tc.arguments["path"]` happens to be missing
  # (e.g. malformed tool calls that are already
  # authoritative-rejected at `LLMTools.validate_args/2`).
  #
  # The on-disk stat (via the sandbox's read-only fast-path) is the
  # authoritative answer for "is there a file at this path RIGHT NOW".
  # The cache is only consulted when the file exists:
  #
  #   * File absent (`:enoent`) → `:ok` regardless of cache
  #     state. The user is allowed to "create new file" or
  #     "recreate deleted" without a prior read; if the file
  #     was deleted between the read and the write, the agent
  #     has the cached content in its own context and can
  #     recreate it.
  #   * File present, cache hit, mtime/size matches → `:ok`.
  #   * File present, cache hit, mtime/size differs →
  #     `{:error, :contents_changed}` — re-read.
  #   * File present, cache miss → `{:error, :never_read}` —
  #     must read first; the file exists so we can't fall
  #     through to the "create new file" path.
  def check_read_policy(raw_path, _state) when not is_binary(raw_path),
    do: :ok

  def check_read_policy(raw_path, state) do
    case resolve_read_target(raw_path, state) do
      {:ok, full_path} -> check_against_on_disk_and_cache(full_path, state)
      :skip -> {:error, :never_read}
    end
  end

  defp resolve_read_target(raw_path, _state) when not is_binary(raw_path),
    do: :skip

  defp resolve_read_target(raw_path, state) do
    case Mounts.resolve(raw_path, Mounts.from_agent(state)) do
      {:ok, full_path} -> {:ok, full_path}
      {:error, _} -> :skip
    end
  end

  # Re-stat first. If the file is gone, the answer is `:ok`
  # regardless of cache state (per the "create new file" /
  # "recreate deleted file" semantics). Otherwise consult
  # the cache.
  defp check_against_on_disk_and_cache(full_path, state) do
    # `full_path` is the path the agent used, in the domain the agent names.
    case Sandbox.stat(full_path, Agent.resolve_caps(state), Mounts.from_agent(state),
           time: :posix
         ) do
      {:error, :enoent} -> :ok
      # A broken sandbox is not a read-before-write problem; let the actual
      # write attempt surface the real error instead of a bogus `:never_read`.
      {:error, :sandbox_setup_failed} -> :ok
      {:ok, %File.Stat{} = stat} -> check_cached_read(full_path, stat, state)
      _ -> {:error, :never_read}
    end
  end

  defp check_cached_read(full_path, %File.Stat{mtime: mtime, size: size}, state) do
    case Map.fetch(state.chat_state.read_files, full_path) do
      :error ->
        {:error, :never_read}

      {:ok, recorded} ->
        if recorded_matches?(recorded, mtime, size),
          do: :ok,
          else: {:error, :contents_changed}
    end
  end

  # Read-time and write-time mtime records both come from the
  # sandbox's read-only stat (`Sandbox.stat/4, time: :posix`), so
  # `mtime` is a POSIX microsecond integer tuple. Comparison is
  # structural.
  defp recorded_matches?(%{mtime: m1, size: s1}, m2, s2),
    do: m1 == m2 and s1 == s2

  defp recorded_matches?(_, _, _), do: false

  # The mounts value carries the workspace root the agent struct was built
  # with (set during `Agent.init/1` from the attrs `:workspace_path`).
  # `ClientConfig` itself does NOT carry it — it's an LLM-level concern, not a
  # request-level one.
  #
  # `Mounts.from_agent/1` matches both keys hard rather than guarding for their
  # absence, and that is safe here: every call site passes an
  # `%Nest.Agents.Agent{}`, whose struct always carries them. The
  # `when is_binary(root)` guard this replaced could only have absorbed a
  # malformed agent-shaped map, which is a bug rather than a case to keep.
end
