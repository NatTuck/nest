defmodule Nest.Agents.Agent.Handlers.CompactionHandler.Regenerator do
  @moduledoc """
  Regeneration helpers for the agent's compaction handler.

  Extracted from `Nest.Agents.Agent.Handlers.CompactionHandler`
  to keep that module under credo's 500-line cap.

  Owns:

    * `regenerate_for_compaction/2` — the entry point.
    * `maybe_fresh_vocation/1` — re-fetches the Vocation row.
    * `rebuild_for_compaction/3` — builds the new state +
      message list with renumbered indices.
    * `persist_message/2` — best-effort writes to the DB.

  ## Stripping

  The `<think>` content of the compactor LLM's response is
  stripped exactly once, here, when the post-compaction
  "Summary of earlier conversation:" user message is built.
  The assistant row in history keeps the raw text (any
  `<think>` markers are visible in the JS history pane via
  `splitThinkFromParts`).

  See `notes/properly-handle-summary-messages-and-openai-think.md`
  for the design.
  """

  require Logger

  alias Nest.Agents.Agent.Init
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Messages.Part
  alias Nest.Messages.ThinkTags
  alias Nest.Messages.User
  alias Nest.Persistence
  alias Nest.Tools
  alias Nest.Vocations

  @doc """
  Regenerate the system prompt + re-fetch all init-time state
  from the latest DB before the message swap. Also persists
  every new message (fresh system, encoded summary) to the
  `messages` table so the post-compaction state survives a
  BEAM restart.

  `summary_text` is the compactor LLM's response text, exactly
  as received. Any `<think>` markers are stripped here (once)
  before the text is wrapped as the post-compaction user
  message:

      "Summary of earlier conversation:\n\n" <> ThinkTags.strip(summary_text)
  """
  @spec regenerate_for_compaction(Nest.Agents.Agent.t(), String.t()) ::
          {Nest.Agents.Agent.t(), [term()]}
  def regenerate_for_compaction(state, summary_text) when is_binary(summary_text) do
    case maybe_fresh_vocation(state) do
      nil ->
        # No fresh vocation — fall through with no swap. The
        # caller (handler) is expected to skip the swap path
        # entirely when this happens. We return the current
        # state unchanged so the caller has something sensible
        # to forward to the lifecycle.
        {state, state.chat_state.messages || []}

      fresh_vocation ->
        {state, new_messages, rows_to_persist} =
          rebuild_for_compaction(state, fresh_vocation, summary_text)

        Enum.each(rows_to_persist, &persist_message(state.name, &1))
        {state, new_messages}
    end
  end

  # Re-fetch the Vocation row by id. If `state.vocation` is
  # nil (a pre-regen test fixture, or the supervisor's no-DB
  # path), there's nothing to refresh; return nil so the caller
  # falls through with the current messages unchanged. If the
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
  defp rebuild_for_compaction(state, fresh_vocation, summary_text) do
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
       %Nest.Messages.System{
         index: marker_index + 1,
         parts: [%Part.Text{text: fresh_prompt}],
         timestamp: now,
         api_logs: []
       }}

    summary_user =
      {:user,
       %User{
         index: marker_index + 2,
         parts: [
           %Part.Text{
             text: "Summary of earlier conversation:\n\n" <> ThinkTags.strip(summary_text)
           }
         ],
         timestamp: now,
         api_logs: []
       }}

    new_messages = [fresh_system, summary_user]

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
