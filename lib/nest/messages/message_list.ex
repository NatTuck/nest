defmodule Nest.Messages.MessageList do
  @moduledoc """
  Pure functions on message lists. Extracted from
  `Nest.Agents.Agent.ChatTurn.Iteration` so the compactor
  and subagent paths can share the same utilities without
  importing iteration-internal functions.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool

  @doc """
  Drop the trailing message if it's an assistant message
  whose parts include a `Part.ToolUse` (an unsatisfied
  tool call — Anthropic's `(2013)` validation rejects
  unpaired `tool_use`).
  """
  @spec drop_trailing_unpaired_tool_call([term()]) :: [term()]
  def drop_trailing_unpaired_tool_call(messages) do
    case List.last(messages) do
      {:assistant, %Assistant{parts: parts}} ->
        if Enum.any?(parts, &match?(%Part.ToolUse{}, &1)) do
          Enum.drop(messages, -1)
        else
          messages
        end

      _ ->
        messages
    end
  end

  @doc """
  Append the clone's own fork rows after the shared prefix.

  Fork semantics are those of Unix `fork/2`: the child shares the
  parent's sequence **including the real trailing `agents-spawn`
  assistant** and gets a different return value at the fork point.
  The child's own rows answer the shared assistant's `Part.ToolUse`
  ids — the `agents-spawn` call reports "you are the clone", any
  sibling tool call is reported as not executed — followed by an
  assistant acknowledgement that names the clone's identity/depth.

  The first returned message is at `next_index`, so
  `next_index` is the clone's fork boundary `F` (`F` is the first
  message the child owns; the shared prefix is everything before
  it). The child's system row is inherited, never re-written.

  When the trailing message is not an assistant carrying tool
  calls (the raw `:spawn_agent_request` path used by tests and the
  no-prior-turn edge case), the spawn call is synthesized so the
  child still gets a coherent, wire-valid origin story. In that
  case the fork begins one row earlier with the synthetic
  assistant `tool_use`.

  Returns `{messages_with_fork, next_index}`.
  """
  @spec build_clone_fork([term()], non_neg_integer(), String.t(), non_neg_integer()) ::
          {[term()], non_neg_integer()}
  def build_clone_fork(messages, next_index, child_name, depth) do
    case trailing_tool_uses(messages) do
      [] -> synthesize_clone_fork(messages, next_index, child_name, depth)
      tool_uses -> answer_clone_fork(messages, next_index, child_name, depth, tool_uses)
    end
  end

  # The parent's real spawn `tool_use` ids, taken from the trailing
  # assistant. Empty when there is no trailing assistant tool call.
  defp trailing_tool_uses(messages) do
    case List.last(messages) do
      {:assistant, %Assistant{parts: parts}} ->
        for %Part.ToolUse{} = tool_use <- parts || [], do: tool_use

      _ ->
        []
    end
  end

  # Unix-fork path: share the real assistant, own only the results
  # and the acknowledgement.
  defp answer_clone_fork(messages, next_index, child_name, depth, tool_uses) do
    results =
      Enum.map(tool_uses, fn %Part.ToolUse{} = tool_use ->
        fork_tool_result(tool_use, child_name, depth)
      end)

    tool_result = {:tool, %Tool{index: next_index, parts: results, api_logs: []}}
    ack = clone_ack(next_index + 1, child_name, depth)

    {messages ++ [tool_result, ack], next_index + 2}
  end

  # Fallback path: no real trailing tool call to share, so the
  # child owns the synthetic spawn assistant as well.
  defp synthesize_clone_fork(messages, next_index, child_name, depth) do
    clone_id = "subagent-clone-#{next_index}"

    assistant_clone =
      {:assistant,
       %Assistant{
         index: next_index,
         parts: [%Part.ToolUse{id: clone_id, name: "agents-spawn", arguments: %{}}],
         api_logs: []
       }}

    tool_result =
      {:tool,
       %Tool{
         index: next_index + 1,
         parts: [
           %Part.ToolResult{
             tool_call_id: clone_id,
             name: "agents-spawn",
             content: clone_notice(child_name, depth),
             arguments: %{},
             is_error: false
           }
         ],
         api_logs: []
       }}

    ack = clone_ack(next_index + 2, child_name, depth)

    {messages ++ [assistant_clone, tool_result, ack], next_index + 3}
  end

  # The fork's return value for one `tool_use` in the shared
  # assistant: the spawn itself reports the clone's identity; any
  # sibling tool call in the same assistant turn is reported as not
  # executed (the clone never ran it, and the wire requires every
  # `tool_use` id to be answered).
  defp fork_tool_result(%Part.ToolUse{name: "agents-spawn"} = tool_use, child_name, depth) do
    %Part.ToolResult{
      tool_call_id: tool_use.id,
      name: tool_use.name,
      content: clone_notice(child_name, depth),
      arguments: tool_use.arguments || %{},
      is_error: false
    }
  end

  defp fork_tool_result(%Part.ToolUse{} = tool_use, _child_name, _depth) do
    %Part.ToolResult{
      tool_call_id: tool_use.id,
      name: tool_use.name,
      content: "Tool call not executed: this agent was forked as a clone before the call ran.",
      arguments: tool_use.arguments || %{},
      is_error: true
    }
  end

  defp clone_notice(child_name, depth) do
    "You are now the delegated clone, named \"#{child_name}\", at depth #{depth}."
  end

  # The clone's acknowledgement: its system message is inherited
  # verbatim from the root ancestor, so this user-visible notice is
  # the only place to state its true identity/depth.
  defp clone_ack(index, child_name, depth) do
    {:assistant,
     %Assistant{
       index: index,
       parts: [
         %Part.Text{
           text:
             "Understood. I am the clone, named \"#{child_name}\", at depth " <>
               "#{depth}. What is my task?"
         }
       ],
       api_logs: []
     }}
  end

  @doc """
  Compute the repair messages needed to keep the sequence valid
  before `incoming` is appended.

  If the trailing message is an assistant carrying `Part.ToolUse`
  calls, every id the assistant is not already answered by
  `incoming` (`incoming` may itself be a `{:tool, _}` result covering
  some ids) must be answered immediately. Returns a list of synthetic
  messages to append before `incoming`:

    * a `{:tool, _}` carrying one `is_error: true` "interrupted"
      `Part.ToolResult` per unpaired id; and
    * when `incoming` is a user message (wire role `user`), a
      synthetic assistant acknowledgement, so the appended user
      message does not create two consecutive `user` wire roles.

  Returns `[]` when nothing needs repairing. This is the append-time
  half of the sequence invariants (`notes/enforce-mesages-seq-invariants.md`);
  the messages are real, persisted, and visible.
  """
  @spec pairing_bridge([term()], term()) :: [term()]
  def pairing_bridge(messages, incoming) do
    case List.last(messages) do
      {:assistant, %Assistant{parts: parts}} ->
        answered = answered_tool_ids(incoming)

        missing =
          for %Part.ToolUse{} = tool_use <- parts || [], tool_use.id not in answered, do: tool_use

        build_bridge(missing, incoming)

      _ ->
        []
    end
  end

  defp answered_tool_ids({:tool, %Tool{parts: parts}}) do
    for %Part.ToolResult{tool_call_id: id} <- parts || [], do: id
  end

  defp answered_tool_ids(_incoming), do: []

  defp build_bridge([], _incoming), do: []

  defp build_bridge(missing_tool_uses, incoming) do
    tool = {:tool, %Tool{parts: Enum.map(missing_tool_uses, &interrupted_result/1), api_logs: []}}

    if match?({:user, _}, incoming) do
      [tool, interrupted_ack()]
    else
      [tool]
    end
  end

  # We know the tool's name from the assistant's `Part.ToolUse`; keep
  # it so the repaired result is shaped like a real one.
  defp interrupted_result(%Part.ToolUse{id: id, name: name}) do
    %Part.ToolResult{
      tool_call_id: id,
      name: name,
      content: "Tool call interrupted before completion (repaired).",
      arguments: %{},
      is_error: true
    }
  end

  # Breaks the two-consecutive-user-roles problem the tool result
  # would otherwise create before the incoming user message.
  defp interrupted_ack do
    {:assistant,
     %Assistant{
       parts: [
         %Part.Text{
           text:
             "The previous tool call was interrupted before it finished. " <>
               "I'll continue from here."
         }
       ],
       api_logs: []
     }}
  end

  @doc """
  Return the Anthropic wire role of the last non-system,
  non-compaction message. Used to decide whether a synthetic
  assistant bridge is needed before appending a new user message.
  """
  @spec last_wire_role([term()]) :: :user | :assistant | nil
  def last_wire_role(messages) do
    messages
    |> Enum.reject(fn {role, _} -> role in [:system, :compaction] end)
    |> List.last()
    |> case do
      {:user, _} -> :user
      {:tool, _} -> :user
      {:assistant, _} -> :assistant
      nil -> nil
    end
  end
end
