defmodule Nest.Agents.Agent.Handlers.CompactionHandler do
  @moduledoc """
  `handle_info/2` handlers for compaction-related events:
  `{:compaction_done, _, _}`, `{:task_compaction_request, _, _}`,
  `{:task_compaction_done, _, _}`, `{:task_compaction_failed, _, _}`.

  Dispatched by `Nest.Agents.Agent.Handlers` based on the
  message tag.

  Per-iteration preflight compaction has been removed; the
  BatchSizer handles tool-result sizing instead. See
  `notes/extract-compaction-and-resumable-chat-turn.md` for the
  design.

  Also owns `regenerate_for_compaction/2` — the shared helper that
  rebuilds the agent's `state.chat_state.messages[0]` (the system
  prompt) from the latest DB state before every compaction. See
  `notes/update-system-msg-on-compaction.md` for the rationale.
  """

  require Logger

  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Compaction
  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Tools
  alias Nest.Vocations

  @doc """
  Dispatch a compaction message. Returns the GenServer's reply
  tuple.
  """
  @spec handle(term(), Nest.Agents.Agent.t()) :: GenServer.reply()
  def handle({:compaction_done, new_messages, continuation}, state) do
    compaction_done(new_messages, continuation, state)
  end

  def handle({:task_compaction_request, task_pid, focus}, state) do
    task_compaction_request(task_pid, focus, state)
  end

  def handle({:task_compaction_done, task_pid, new_messages}, state) do
    task_compaction_done(task_pid, new_messages, state)
  end

  def handle({:task_compaction_failed, task_pid, reason}, state) do
    task_compaction_failed(task_pid, reason, state)
  end

  defp compaction_done(new_messages, continuation, state) do
    Logger.info(
      "Compaction complete: agent=#{state.name} from=#{length(state.chat_state.messages)} to=#{length(new_messages)}"
    )

    # Regenerate the system prompt and persist the new messages
    # before swapping. See `regenerate_for_compaction/2` for the
    # full rationale.
    {state, new_messages} = regenerate_for_compaction(state, new_messages)

    # Archive the previous messages to history with a marker,
    # then replace state.chat_state.messages with the compacted state.
    state = archive_and_compact(state, new_messages)

    case continuation do
      {:chat_continuation, {content, mode}} ->
        # The `cancelled` flag is set when the user clicked Stop
        # while a pre-flight compaction was in flight. Discard the
        # continuation — the agent's chat task has already exited
        # (or is about to) and we don't want to spawn a new one.
        if state.chat_state.cancelled do
          {:noreply, state}
        else
          state = ChatPipeline.resume_after_compaction(state, content, mode)
          {:noreply, state}
        end

      {:task_compaction_continuation, task_pid} ->
        # The chat task invoked the `context` tool's compact action
        # and is blocked on a receive for the result. Send it the
        # new messages so it can construct the tool result string.
        # If the user clicked Stop, the chat task is no longer in
        # this receive, so the `send` is a no-op — the message lands
        # in a dead process's mailbox and is silently discarded.
        send(task_pid, {:task_compaction_done, new_messages})
        {:noreply, state}
    end
  end

  defp task_compaction_request(task_pid, _focus, state) do
    # The chat task is mid-flow and asked for explicit
    # compaction via the `context` tool. Spawn the compactor
    # and send the result back to the task when done. The task
    # will unblock its receive and use the result.
    Compaction.spawn(
      self(),
      state.client_config,
      state.llm_metrics.context_limit,
      state.chat_state.messages || [],
      {:task_compaction_continuation, task_pid}
    )

    {:noreply, state}
  end

  defp task_compaction_done(task_pid, new_messages, state) do
    Logger.info(
      "context tool compact: agent=#{state.name} from=#{length(state.chat_state.messages)} to=#{length(new_messages)}"
    )

    {state, new_messages} = regenerate_for_compaction(state, new_messages)
    state = archive_and_compact(state, new_messages)
    send(task_pid, {:task_compaction_done, new_messages})
    {:noreply, state}
  end

  defp task_compaction_failed(task_pid, reason, state) do
    Logger.warning("context tool compact failed: #{inspect(reason)}")
    send(task_pid, {:task_compaction_failed, reason})
    {:noreply, state}
  end

  # `archive_and_compact` lives in the GenServer module because
  # it mutates chat history; we forward to it from here.
  defp archive_and_compact(state, new_messages) do
    Nest.Agents.Agent.__archive_and_compact__(state, new_messages)
  end

  # Regenerate the system prompt + re-fetch all init-time state
  # from the latest DB before the message swap. Also persists
  # every new message (fresh system, encoded summary, compactor's
  # other output) to the `messages` table so the post-compaction
  # state survives a BEAM restart.
  #
  # The compactor's `new_messages` is expected to start with a
  # `{:system, _}` carrying the head/tail summary. The pattern
  # match below is structural — if it fails, something else is
  # broken (the compactor's contract is violated), and we want
  # that to raise loudly rather than silently corrupt the agent.
  @spec regenerate_for_compaction(Nest.Agents.Agent.t(), [term()]) ::
          {Nest.Agents.Agent.t(), [term()]}
  defp regenerate_for_compaction(state, compactor_messages) do
    [{:system, %System{parts: [%Part.Text{text: summary_text}]}} | rest] =
      compactor_messages

    case maybe_fresh_vocation(state) do
      nil ->
        {state, compactor_messages}

      fresh_vocation ->
        {state, new_messages, rows_to_persist} =
          rebuild_for_compaction(state, fresh_vocation, summary_text, rest)

        Enum.each(rows_to_persist, &persist_message(state.name, &1))
        {state, new_messages}
    end
  end

  # Re-fetch the Vocation row by id. If `state.vocation` is
  # nil (a pre-regen test fixture, or the supervisor's no-DB
  # path), there's nothing to refresh; return nil so the caller
  # falls through to the compactor's output as-is. If the
  # lookup returns nil or raises (transient DB blip, row briefly
  # missing during a transaction, etc.), log a warning and
  # return nil. The next compaction will retry — the system is
  # expected to come back to a consistent state quickly.
  defp maybe_fresh_vocation(state) do
    case state.vocation do
      nil ->
        nil

      %Vocations.Vocation{id: vocation_id} ->
        case Vocations.get_vocation(vocation_id) do
          %Vocations.Vocation{} = v ->
            v

          nil ->
            Logger.warning(
              "Vocation #{vocation_id} not found during compaction regeneration; using cached state."
            )

            nil
        end
    end
  rescue
    error ->
      Logger.warning(
        "Vocation lookup failed during compaction regeneration: #{inspect(error)}. Using cached state."
      )

      nil
  end

  # Build the new `state` and `new_messages` list. Also returns
  # the list of rows to persist (in index order, with the same
  # indices `Lifecycle.apply/2` will assign them).
  defp rebuild_for_compaction(state, fresh_vocation, summary_text, rest) do
    {context_limit, context_limit_source} = Init.initial_context_limit(state.model)

    {fresh_prompt, _mode, _tool_names, _cached_vocation} =
      SystemPrompt.compose_vocation_config(
        fresh_vocation,
        state.workspace_path,
        {context_limit, context_limit_source}
      )

    marker_index = state.chat_state.next_message_index
    now = DateTime.utc_now()

    fresh_system =
      {:system,
       %System{
         index: marker_index + 1,
         parts: [%Part.Text{text: fresh_prompt}],
         timestamp: now,
         api_logs: []
       }}

    summary_user =
      {:user,
       %User{
         index: marker_index + 2,
         parts: [%Part.Text{text: "Summary of earlier conversation:\n\n" <> summary_text}],
         timestamp: now,
         api_logs: []
       }}

    # Renumber the compactor's other output so their indices
    # are unique and start at `marker_index + 3` (after the
    # fresh system and the encoded summary). The compactor's
    # input indices are opaque to us — they may collide with
    # the fresh indices or each other.
    renumbered_rest = Compaction.assign_indices(rest, marker_index + 3)

    new_messages = [fresh_system, summary_user | renumbered_rest]

    fresh_tools =
      Tools.get_functions(fresh_vocation.tools || [], state.workspace_path, state.tmp_path)

    new_state = %{
      state
      | vocation: fresh_vocation,
        tools: fresh_tools,
        llm_metrics: %{
          state.llm_metrics
          | context_limit: context_limit,
            context_limit_source: context_limit_source
        }
    }

    rows_to_persist = new_messages
    {new_state, new_messages, rows_to_persist}
  end

  # Persist a single post-compaction message. Failures are logged
  # but don't fail the in-memory regeneration — the in-memory
  # state is the source of truth for the current turn; the DB is
  # for cross-restart recovery. Same pattern as
  # `AgentPersistence.append_message/3`.
  #
  # `:agent_not_found` is the common case in tests that start
  # an agent process via `start_supervised!/1` without
  # inserting a corresponding `agents` row — the in-memory
  # state is the only source of truth, and persistence is
  # not part of those tests' contract. We log at `:debug`
  # (silent at the default `:info` log level) so test runs
  # aren't noisy. Any other error is a real DB failure and
  # warrants a `:warning`.
  defp persist_message(name, {role, _struct} = message) do
    case Persistence.insert_message(name, message) do
      {:ok, _} ->
        :ok

      {:error, :agent_not_found} ->
        Logger.debug(
          "Skipping persistence of post-compaction #{role} message for agent #{name}: " <>
            "no agents row (in-memory only)"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to persist post-compaction #{role} message for agent #{name}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
