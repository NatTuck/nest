defmodule Nest.Agents.Agent.Compaction.Trigger do
  @moduledoc """
  Trigger logic for spawning the compactor's chat turn.

  The trigger is called from two places:

    * **Post-turn (Trigger A)**: from
      `Nest.Agents.Agent.ChatPipeline.handle_chat/3` when
      preflight decides the next LLM call won't fit. The
      held user message stays in `pending_user_message`;
      the compactor's chat turn runs with
      `carried_entry = nil`. On success, the result
      handler appends the held user message and spawns a
      normal `{:user_message, _}` chat turn.

    * **Mid-turn (Trigger B/C)**: from the in-process turn
      (`Nest.Agents.Agent.Turn`) when (a) projected tool
      results would push past `context_limit - reserve`
      or (b) the LLM emitted `context-compact` as the sole
      tool call. The turn sends
      `{:needs_compaction, _, carried_entry}` to the
      Agent; this trigger spawns the compactor's chat
      turn with the carried entry (a `{:tool_call, _, _,
      _}` or `{:compact_tool, _, _, _}`). On success, the
      result handler spawns a fresh chat turn with the
      same carried entry (the tool call sequence resumes).

  Both paths funnel through `start/2` (the actual
  spawn). The preflight check (via
  `Nest.Tokens.Compactor.compute_summary_budget/4`) and
  the loop-breaker check (via
  `Nest.Agents.Agent.Compaction.ResultHandler.check_consecutive/1`)
  are run in the same order. On `:reserve_exhausted`,
  `chat:error` is broadcast and the agent stays in its
  current state (no spawn).
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.ChatPipeline
  alias Nest.Agents.Agent.Compaction.Overflow
  alias Nest.Agents.Agent.Compaction.ResultHandler
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Agents.Agent.Turn
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.Streaming
  alias Nest.Tokens.Compactor, as: TokensCompactor

  @doc """
  Post-turn (Trigger A) trigger. Called from
  `ChatPipeline.handle_chat/3` after the preflight
  decides the next LLM call won't fit. Sets
  `:compacting` status, broadcasts it, runs the
  loop-breaker check, then starts the compactor's chat
  turn with `carried_entry = nil`.

  The held user message stays in `pending_user_message`;
  on success the result handler appends it via
  `ChatPipeline.resume_with_pending/1`.
  """
  @spec post_turn(Agent.t()) :: Agent.t()
  def post_turn(state) do
    state = %{
      state
      | live: %{state.live | machine: Machine.to_compaction_generating(state.live.machine)}
    }

    Broadcasts.status(state)

    case ResultHandler.check_consecutive(state) do
      :refuse ->
        # Loop detected. The ResultHandler already
        # broadcast the loop event and set
        # `:compaction_loop_detected`. The pending user
        # message stays set so the next chat:message
        # (after OK) can re-attach; for now, leave the
        # agent in the loop state and return.
        state

      {:ok, state} ->
        start(state, nil)
    end
  end

  @doc """
  Mid-turn (Trigger B/C) trigger. Called from
  `Compaction.ResultHandler.needs_entry/2`. Sets
  `:compacting` status, broadcasts it, runs the
  loop-breaker check, then starts the compactor's chat
  turn with `carried_entry` (a `{:tool_call, _, _, _}`
  or `{:compact_tool, _, _, _}`).
  """
  @spec mid_turn(Agent.t(), Agent.Machine.entry() | nil) :: Agent.t()
  def mid_turn(state, carried_entry) do
    case ResultHandler.check_consecutive(state) do
      :refuse ->
        state

      {:ok, state} ->
        start(state, carried_entry)
    end
  end

  # Common spawn path for both post-turn and mid-turn
  # triggers. Renders the system prompt via
  # `SystemPrompt.compose_vocation_config/5` (single source
  # of truth for the system size when a vocation is present),
  # checks the 25% safety budget, computes the summary budget,
  # builds the suffix, appends it to the messages list (the
  # user sees the compaction request), then starts the in-process
  # turn (`Turn.start/4`) with `{:compaction, _, carried_entry}`.
  #
  # When `state.vocation` is `nil` (test fixtures use this as
  # a "minimal default" sentinel), fall back to extracting the
  # rendered prompt text from the system message at
  # `state.chat_state.messages[0]` — the same source the
  # pre-refactor code used. This keeps those fixtures
  # working while the production path (vocations are always
  # present) still uses the rendered string as the source of
  # truth.
  defp start(state, carried_entry) do
    messages = state.chat_state.messages || []

    system_prompt = render_system_prompt(state, messages)

    cond do
      system_prompt != nil and
          not SystemPrompt.within_size_budget?(system_prompt, state.llm_metrics.context_limit) ->
        broadcast_oversized(state, system_prompt)

      system_prompt == nil ->
        broadcast_reserve_exhausted(state, nil)
        state

      true ->
        case TokensCompactor.compute_summary_budget(
               state.llm_metrics.context_limit,
               system_prompt,
               messages,
               nil
             ) do
          {:ok, _n, rendered_suffix} ->
            staged = stage_request(messages, rendered_suffix)
            spawn_compaction_turn(state, carried_entry, staged)

          {:error, :reserve_exhausted} ->
            broadcast_reserve_exhausted(state, system_prompt)
            state
        end
    end
  end

  # Build the compaction request additions that are staged (not persisted)
  # until the compaction commits: an assistant bridge when the persisted
  # wire tail is a user/tool role (so appending the user suffix does not
  # create two consecutive user roles), followed by the `[mode: compact]`
  # suffix. Both are persisted together with the summary on success.
  defp stage_request(messages, suffix) do
    base = MessageList.drop_trailing_unpaired_tool_call(messages)

    if MessageList.last_wire_role(base) == :user do
      [synthetic_assistant_bridge(), suffix]
    else
      [suffix]
    end
  end

  # The request-only alternation bridge, now staged and persisted on commit.
  defp synthetic_assistant_bridge do
    {:assistant,
     %Assistant{
       parts: [%Part.Text{text: "Let me pause to summarize."}],
       timestamp: DateTime.utc_now(),
       api_logs: []
     }}
  end

  # Render the system prompt. Production path: compose from
  # `state.vocation`. Test-fixture / legacy path (no
  # vocation): extract the rendered text from the system
  # message at `state.chat_state.messages[0]`. Both branches
  # produce a string suitable for `Overflow.system_size/1`
  # and `compute_summary_budget/5`.
  defp render_system_prompt(state, messages) do
    if state.vocation do
      {system_prompt, _mode, _tools, _vocation} =
        SystemPrompt.compose_vocation_config(
          state.vocation,
          state.workspace_path,
          {state.llm_metrics.context_limit, state.llm_metrics.context_limit_source},
          state.name,
          state.depth
        )

      system_prompt
    else
      case Enum.find(messages, &match?({:system, _}, &1)) do
        nil -> nil
        {:system, %Nest.Messages.System{parts: parts}} -> system_text_from_parts(parts)
      end
    end
  end

  defp system_text_from_parts(parts) do
    Enum.map_join(parts, "", fn
      %Nest.Messages.Part.Text{text: text} -> text || ""
      _ -> ""
    end)
  end

  # Spawn the compactor's chat turn with a *staged* request. Nothing from
  # the request (assistant bridge + `[mode: compact]` suffix) is persisted
  # here: the staged list is carried in the entry and written by
  # `ResultHandler` only on success. A failed compaction leaves no rows.
  #
  # The summary assistant will be persisted at
  # `next_message_index + length(staged)` once the staged request lands, so
  # we key the streaming accumulator (and the in-process `Turn`'s
  # `active_message_index`) to that provisional index.
  defp spawn_compaction_turn(state, carried_entry, staged) do
    provisional_index = state.chat_state.next_message_index + length(staged)

    next_state = %{
      state
      | live: %{state.live | streaming_acc: Streaming.new(provisional_index)}
    }

    {_effective_mode, caps} =
      ChatPipeline.resolve_mode_and_caps(
        Map.get(next_state, :mode),
        Map.get(next_state, :vocation),
        Map.get(next_state, :workspace_path),
        Map.get(next_state, :tmp_path)
      )

    Turn.start(
      next_state,
      next_state.chat_state.messages,
      {:compaction, staged, carried_entry},
      caps
    )
  end

  # `:reserve_exhausted` from `compute_summary_budget/5`
  # (or `system_prompt == nil` upstream) surface the same
  # overflow to the user — the compactor can't run. The
  # message construction is centralized in `Overflow` so
  # the two paths can't drift apart.
  defp broadcast_reserve_exhausted(state, system_prompt) do
    Overflow.broadcast(
      state,
      inspect(__MODULE__),
      "compact",
      system_prompt,
      :reserve_exhausted
    )
  end

  # Belt-and-suspenders: the rendered system prompt exceeds
  # the 25% safety budget for the context window. The agent
  # transitions to `:context_overflow` (blocking future
  # `chat:message` traffic) and returns the updated state.
  defp broadcast_oversized(state, system_prompt) do
    state = %{
      state
      | live: %{state.live | machine: Machine.to_blocked(state.live.machine, :context_overflow)}
    }

    Broadcasts.status(state)

    Overflow.broadcast(
      state,
      inspect(__MODULE__),
      "compact",
      system_prompt,
      :system_oversized
    )

    state
  end
end
