defmodule Nest.Agents.Agent.Init.InterruptedToolCall do
  @moduledoc """
  Load-time heal for a persisted active sequence whose only defect is a
  trailing assistant `tool_use` with no result — a turn that died before
  its tool result was committed (`notes/enforce-mesages-seq-invariants.md`
  §4).

  The run-time owner is gone, so there is nothing to continue: the heal
  answers the call with the canonical `is_error` result, then appends the
  assistant acknowledgement the append-time bridge would otherwise add
  later. This leaves the tail on an `assistant` rather than a `tool`
  (wire role `user`), so the next user turn appends cleanly. The agent
  comes up `:idle` without spending an LLM call. Unlike
  `Init.NeedsRepair`, this is not a blocking state — an interrupted tool
  call is a valid outcome, not corruption.
  """

  require Logger

  alias Nest.Messages.MessageList
  alias Nest.Messages.Part

  @spec heal(Nest.Agents.Agent.t(), [Part.ToolUse.t()]) :: Nest.Agents.Agent.t()
  def heal(state, tool_uses) do
    Logger.warning(
      "Agent #{state.name} (space #{state.space_id}) loaded an interrupted tool call; " <>
        "answering #{length(tool_uses)} unpaired tool_use id(s) with an error result and idling."
    )

    case MessageList.interrupted_tool_result(tool_uses) do
      nil ->
        state

      tool_msg ->
        append_or_keep(state, [tool_msg, MessageList.repair_ack()])
    end
  end

  # The canonical append path refuses (raises) when the conversation is
  # already `:cannot_compact`. In that pathological case, leave the state
  # untouched and log; the send guard still refuses to send the invalid
  # tail, so we degrade safely rather than crash-loop the Agent.
  defp append_or_keep(state, messages) do
    {_stamped, state} = Nest.Agents.Agent.__append_messages__(state, messages)
    state
  rescue
    error ->
      Logger.error(
        "Agent #{state.name} (space #{state.space_id}) could not heal its interrupted " <>
          "tool call: #{Exception.message(error)}"
      )

      state
  end
end
