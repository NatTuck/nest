defmodule Nest.Agents.Agent.ChatTurnSpawner do
  @moduledoc """
  Single entry point for spawning a `ChatTurn`. The entry
  tag is the contract — it determines what the new ChatTurn's
  first iteration does.

  Entry shapes (see `Nest.Agents.Agent.ChatTurn.State`):

    * `{:user_message, User.t()}` — Trigger 1 (or the user's
      pipeline input at idle). The user message has already
      been appended to `state.chat_state.messages`; the new
      ChatTurn's first iter calls the LLM.

    * `{:tool_call, Assistant.t(), non_neg_integer(),
      pos_integer()}` — Trigger 2. The carried tool_call_message
      is already in `state.chat_state.messages`; the new
      ChatTurn's first iter runs `execute_pending_tool_calls`.
      Iteration + max_iterations preserve the count across the
      compaction boundary.

    * `{:compact_tool, [Assistant.t(), Tool.t()],
      non_neg_integer(), pos_integer()}` — Trigger 3. The
      carried pair [tool_call, tool_result] is already in
      `state.chat_state.messages`; the new ChatTurn's first
      iter falls through to the LLM (last message is the tool
      result, not a tool_call).

    * `{:compaction, term(), entry() | nil}` — the
      compactor's own chat turn. The `[mode: compact]`
      suffix is already in `state.chat_state.messages`; the
      new ChatTurn's first iter calls the LLM with
      `tools: nil, tool_choice: :none`, then sends
      `{:compaction_done, summary_text, carried_entry}` to
      the Agent when finished. The middle slot is reserved
      for a future contract (currently `nil` from the
      Trigger — `lifecycle.ex`'s finalize destructure
      currently discards it). The third element is `nil`
      for Trigger A (post-turn) and the carried
      `{:tool_call, _, _, _}` /
      `{:compact_tool, _, _, _}` for Trigger B (mid-turn).

  All four production entries are explicit. No `nil` case
  (removed in the continuation → entry rename — every chat
  turn has a meaningful entry, even the default user message
  case which is `{:user_message, %User{parts: []}}`).
  """

  alias Nest.Agents.Agent.ChatTurnSupervisor

  require Logger

  @doc """
  Spawn a fresh `ChatTurn` under `ChatTurnSupervisor`, seeded
  with `messages` as `ctx.messages` and `entry` as the
  init info. `caps` is the resolved capability map for the
  effective mode (caller-resolved; this module doesn't
  depend on `Vocations`).

  Returns the new state with `chat_turn_pid` set (or `nil` if
  the supervisor is saturated). The four production call
  sites — Trigger 1 preflight `:fits`, Trigger 1 post-compaction,
  Trigger 2 post-compaction, Trigger 3 post-compaction,
  compactor's own chat turn — all funnel through this function.
  """
  @spec spawn(Nest.Agents.Agent.t(), list(), Nest.Agents.Agent.ChatTurn.State.entry(), map()) ::
          Nest.Agents.Agent.t()
  def spawn(state, messages, entry, caps) do
    agent_pid = self()

    ctx = %{
      agent_pid: agent_pid,
      agent_name: state.name,
      client_config: state.client_config,
      tools: state.tools,
      tool_choice: :auto,
      caps: caps,
      context_limit: state.llm_metrics.context_limit,
      messages: messages,
      tmp_path: state.tmp_path,
      crossed_thresholds: state.chat_state.crossed_thresholds
    }

    case ChatTurnSupervisor.start_chat_turn(agent_pid, ctx, entry) do
      {:ok, chat_turn_pid} ->
        %{state | chat_state: %{state.chat_state | chat_turn_pid: chat_turn_pid}}

      _ ->
        Logger.warning("ChatTurnSpawner.spawn: supervisor saturated for agent=#{state.name}")

        %{state | chat_state: %{state.chat_state | chat_turn_pid: nil}}
    end
  end
end
