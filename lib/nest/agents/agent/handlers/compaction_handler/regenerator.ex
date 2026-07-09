defmodule Nest.Agents.Agent.Handlers.CompactionHandler.Regenerator do
  @moduledoc """
  Regeneration helpers for the agent's compaction handler.

  Extracted from `Nest.Agents.Agent.Handlers.CompactionHandler`
  to keep that module under credo's 500-line cap.

  Owns:

    * `regenerate_for_compaction/2` — the entry point.
    * `maybe_fresh_vocation/1` — re-fetches the Vocation row.
    * `rebuild_for_compaction/4` — builds the new state +
      message list with renumbered indices.
    * `persist_message/2` — best-effort writes to the DB.

  See `notes/update-system-msg-on-compaction.md` for the design.
  """

  require Logger

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
  Regenerate the system prompt + re-fetch all init-time state
  from the latest DB before the message swap. Also persists
  every new message (fresh system, encoded summary, compactor's
  other output) to the `messages` table so the post-compaction
  state survives a BEAM restart.

  The compactor's `new_messages` is expected to be
  `[original_system, wrap_summary(head_summary), ...rest]`.
  The encoded summary-as-user MUST contain the LLM summary,
  not the original system prompt.

  ## Destructuring

  We destruct the LLM summary from the compactor output by
  finding a `{:system, %System{parts: [%Part.Text{text: _}]}}`
  shape. The original system at position 0 typically has
  multi-part or rich content (vocations render prose into
  multiple text parts); the wrap_summary system at position 1
  is always exactly one `Part.Text`. We pick the first
  system-shaped entry whose parts list is `[%Part.Text{}]` —
  that distinguishes the wrap_summary from the original.

  If no such system is found, we fall back to position 0
  (legacy/early-compactor behavior) and log a debug warning.
  """
  @spec regenerate_for_compaction(Nest.Agents.Agent.t(), [term()]) ::
          {Nest.Agents.Agent.t(), [term()]}
  def regenerate_for_compaction(state, compactor_messages) do
    {_original_system, summary_text, rest} = split_compactor_output(compactor_messages)

    case maybe_fresh_vocation(state) do
      nil ->
        # No fresh vocation — fall through with the compactor's
        # output as-is. The state-vocation is preserved.
        {state, compactor_messages}

      fresh_vocation ->
        {state, new_messages, rows_to_persist} =
          rebuild_for_compaction(state, fresh_vocation, summary_text, rest)

        Enum.each(rows_to_persist, &persist_message(state.name, &1))
        {state, new_messages}
    end
  end

  # Split `[original_system, wrap_summary, ...rest]` into
  # `{original_system, summary_text, rest}`.
  #
  # Production compactor output: position 0 is the original
  # system (rich content), position 1 is the wrap_summary
  # (a single `Part.Text`).
  #
  # Test fixtures vary — some mimic the OLD shape
  # (`[system_with_summary, user]`) where position 0 holds the
  # summary text. We accept both by shape:
  # * If position 1 is a `{:system, _}` matching the wrap_summary
  #   shape, use position 1.
  # * Else if position 0 matches the wrap_summary shape, use
  #   position 0 (legacy/early-compactor).
  # * Else default to position 0's text (best-effort).
  defp split_compactor_output([first | rest]) when is_list(rest) do
    cond do
      wrap_summary?(Enum.at(rest, 0)) ->
        {first, text_from_system(Enum.at(rest, 0)), Enum.drop(rest, 1)}

      wrap_summary?(first) ->
        {first, text_from_system(first), rest}

      true ->
        # Best-effort fallback: take whatever text is in the
        # first system we can find. Logged at debug because
        # production shouldn't hit this branch.
        require Logger

        Logger.debug(
          "compactor output did not match [system, wrap_summary] shape; using position 0 text"
        )

        {first, text_from_system(first), rest}
    end
  end

  defp split_compactor_output([]) do
    raise "compactor returned an empty list; cannot derive summary_text"
  end

  defp split_compactor_output(other) do
    raise "compactor returned a non-list shape: #{inspect(other)}"
  end

  defp wrap_summary?({:system, %System{parts: [%Part.Text{}]}}), do: true
  defp wrap_summary?(_), do: false

  defp text_from_system({:system, %System{parts: [%Part.Text{text: text}]}}), do: text

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
