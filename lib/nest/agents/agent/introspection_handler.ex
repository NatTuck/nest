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
  by `CompactionHandler.check_consecutive/1` and resets via
  the append_message path in the agent's `handle_call/3`.

  The `:check_read_policy/2` clause is the synchronous
  pre-call gate used by `BatchSizer.execute_one/2` (in a
  worker task) before any `write_file` runs. It looks up
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
  alias Nest.Agents.Agent.ModelHandler
  alias Nest.LLM.Client
  alias Nest.Messages.Streaming
  alias Nest.Tokens.ConversationSize
  alias Nest.Vocations

  @doc """
  Dispatch an introspection `handle_call/3` message. Returns
  the GenServer's reply tuple.
  """
  @spec handle(term(), GenServer.from(), Agent.t()) :: GenServer.reply()
  def handle({:set_consecutive_compaction_count, n}, _from, state) when is_integer(n) do
    {:reply, :ok, %{state | live: %{state.live | consecutive_compaction_count: n}}}
  end

  def handle(:get_consecutive_compaction_count, _from, state) do
    {:reply, state.live.consecutive_compaction_count, state}
  end

  def handle(:get_public_info, _from, state) do
    build_public_info(state)
  end

  def handle(:get_messages, _from, state) do
    {:reply, state.chat_state.messages, state}
  end

  # Returns `{messages, cancelled}` so the ChatTurn can
  # short-circuit on user-initiated stops without waiting
  # for the next `:stop_chat` message to be processed.
  def handle(:get_messages_with_cancelled, _from, state) do
    {:reply, {state.chat_state.messages, state.live.cancelled}, state}
  end

  def handle(:get_crossed_thresholds, _from, state) do
    {:reply, state.live.crossed_thresholds, state}
  end

  def handle(:get_next_index, _from, state) do
    {:reply, state.chat_state.next_message_index, state}
  end

  def handle(:get_history, _from, state) do
    {:reply, state.chat_state.history || [], state}
  end

  # Test-only introspection: returns the assembled system
  # prompt (the content of the `{:system, _}` message at
  # position 0 of `state.chat_state.messages`).
  def handle(:get_system_prompt, _from, state) do
    {:reply, system_prompt_from_messages(state.chat_state.messages), state}
  end

  def handle(:get_chat_turn_pid, _from, state) do
    {:reply, state.live.chat_turn_pid, state}
  end

  # Test-friendly: returns the `pending_children` map so
  # a test can assert which workers are currently parked
  # on an `agents/spawn` (with `query`) tool call. Production
  # code should use `:get_total_usage` / `get_public_info`
  # instead.
  def handle(:get_pending_children, _from, state) do
    {:reply, state.chat_state.pending_children, state}
  end

  def handle(:get_total_usage, _from, state) do
    {:reply,
     Broadcasts.total_usage(state.llm_metrics.usage_totals, state.llm_metrics.descendant_usage),
     state}
  end

  # Pre-call gate for `write_file`. Looks up the cache entry
  # for `path`; if absent → the agent has not yet called
  # `read_file` (or the path has been cleared by a post-
  # compaction reset). If present, re-stat the file at the
  # full path; the on-disk mtime/size must equal the recorded
  # pair — otherwise the file has been modified since the
  # read or since the last `write_file`. Both error cases map
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

  # Pre-call gate for `write_file`. Looks up the cache entry
  # for `path`; if absent → the agent has not yet called
  # `read_file` (or the path has been cleared by a post-
  # compaction reset). If present, re-stat the file at the
  # full path; the on-disk mtime/size must equal the recorded
  # pair — otherwise the file has been modified since the
  # read or since the last `write_file`. Both error cases map
  # to a stable atom (`:never_read` / `:contents_changed`)
  # the worker translates to user-facing strings.
  #
  # Path resolution mirrors the read-tracking write at
  # `LLMStreamHandler` so the cache keys match the lookup
  # keys. Both treat absolute paths as-is and join relative
  # ones onto the per-agent workspace root.
  # Use the cached Vocation struct from state — no DB work
  # in the handler. The struct was loaded by the calling
  # process and passed into init/1 via `:vocation` in attrs.
  defp build_public_info(state) do
    vocation = state.vocation

    public_info = %{
      name: state.name,
      space_id: state.space_id,
      model: state.model,
      message_count: length(state.chat_state.messages),
      status: state.live.status,
      vocation_id: state.vocation_id,
      tmp_path: state.tmp_path,
      # Run the streaming accumulator (or nil) through
      # `Streaming.to_json_safe/1` so `get_public_info/1`
      # is JSON-encodable end-to-end. Lobby and AgentChannel
      # both consume this map and Phoenix.Channel.push/3
      # encodes it as JSON before the WS frame hits the wire;
      # a raw `%AssistantAccumulator{}` struct trips
      # `Protocol.UndefinedError` at `Jason.encode/1` time.
      partial: Streaming.to_json_safe(state.live.streaming_acc),
      modes: Vocations.list_modes(vocation),
      default_mode: Vocations.default_mode(vocation),
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
      shared: state.shared,
      # Direct usage (this agent's own LLM calls).
      usage:
        Map.put(
          state.llm_metrics.usage_totals,
          :context_input_tokens,
          ConversationSize.size(state.chat_state.messages)
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

    {:reply, public_info, state}
  end

  defp system_prompt_from_messages([{:system, %{parts: parts}} | _]) when is_list(parts) do
    Client.text_from_parts(parts)
  end

  defp system_prompt_from_messages(_), do: nil

  # Three-step pipeline (resolve path → stat the on-disk file
  # → match against the cache) split into flat helpers. The
  # `cond`/`case` nesting in a single function tripped credo's
  # "max depth 2" rule; this version is `2 + 1 + 1`.
  #
  # No-path is a `BatchSizer` defensive fallback (the
  # `BatchSizer.FilePolicy.check/2` call only fires for
  # `write_file` tool calls, and only those carry a `path`
  # argument). A non-binary `raw_path` short-circuits to
  # `:ok` so the worker doesn't refuse legitimate calls
  # where `tc.arguments["path"]` happens to be missing
  # (e.g. malformed tool calls that are already
  # authoritative-rejected at `LLMTools.validate_args/2`).
  #
  # The on-disk `File.stat/1` is the authoritative answer for
  # "is there a file at this path RIGHT NOW". The cache is
  # only consulted when the file exists:
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
    case resolve_policy_path(raw_path, state) do
      {:ok, full_path} -> {:ok, full_path}
      :skip -> :skip
    end
  end

  # Re-stat first. If the file is gone, the answer is `:ok`
  # regardless of cache state (per the "create new file" /
  # "recreate deleted file" semantics). Otherwise consult
  # the cache.
  defp check_against_on_disk_and_cache(full_path, state) do
    case File.stat(full_path, time: :posix) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{} = stat} -> check_cached_read(full_path, stat, state)
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

  # Read-time and write-time mtime records both come from
  # `File.stat(full_path, time: :posix)`, so `mtime` is a
  # POSIX microsecond integer tuple. Comparison is structural.
  defp recorded_matches?(%{mtime: m1, size: s1}, m2, s2),
    do: m1 == m2 and s1 == s2

  defp recorded_matches?(_, _, _), do: false

  defp resolve_policy_path(path, state) do
    if Path.type(path) == :absolute do
      {:ok, path}
    else
      resolve_relative_policy_path(path, workspace_root(state))
    end
  end

  defp resolve_relative_policy_path(path, root) when is_binary(root),
    do: {:ok, Path.join(root, path)}

  defp resolve_relative_policy_path(_path, _root), do: :skip

  # The workspace root lives on the agent struct directly
  # (set during `Agent.init/1` from the attrs `:workspace_path`).
  # `ClientConfig` itself does NOT carry the workspace root —
  # it's an LLM-level concern, not a request-level one.
  defp workspace_root(state) do
    case state do
      %{workspace_path: root} when is_binary(root) -> root
      _ -> nil
    end
  end
end
