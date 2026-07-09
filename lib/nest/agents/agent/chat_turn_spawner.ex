defmodule Nest.Agents.Agent.ChatTurnSpawner do
  @moduledoc """
  Single entry point for spawning a `ChatTurn`. The continuation
  tag is the contract — it determines what the new ChatTurn's
  first iteration does.

  Continuation shapes (see `Nest.Agents.Agent.ChatTurn.State`):

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

  All three production continuations are explicit. A future
  `/tool` slash command at idle could pass `{:tool_call, _, _, _}`
  to force the LLM out of chat-only mode into tool mode — no
  shape changes needed here.
  """

  alias Nest.Agents.Agent.ChatTurnSupervisor

  require Logger

  @doc """
  Spawn a fresh `ChatTurn` under `ChatTurnSupervisor`, seeded
  with `messages` as `ctx.messages` and `continuation` as the
  init info. `caps` is the resolved capability map for the
  effective mode (caller-resolved; this module doesn't
  depend on `Vocations`).

  Returns the new state with `chat_turn_pid` set (or `nil` if
  the supervisor is saturated). The four production call
  sites — Trigger 1 preflight `:fits`, Trigger 1 post-compaction,
  Trigger 2 post-compaction, Trigger 3 post-compaction — all
  funnel through this function; the compaction handler's
  case-contination arms at the compactor's output drop to a
  single call here.
  """
  @spec spawn(Nest.Agents.Agent.t(), list(), term(), map()) :: Nest.Agents.Agent.t()
  def spawn(state, messages, continuation, caps) do
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
      tmp_path: state.tmp_path
    }

    case ChatTurnSupervisor.start_chat_turn(agent_pid, ctx, continuation) do
      {:ok, chat_turn_pid} ->
        %{state | chat_state: %{state.chat_state | chat_turn_pid: chat_turn_pid}}

      _ ->
        Logger.warning("ChatTurnSpawner.spawn: supervisor saturated for agent=#{state.name}")

        %{state | chat_state: %{state.chat_state | chat_turn_pid: nil}}
    end
  end
end
