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
  If the trailing message is an assistant carrying an
  `agents/spawn` `Part.ToolUse`, drop it and return the
  spawn's `query` text. Otherwise return `{messages, nil}`.

  Used by the subagent spawn (clone-context) path so a
  synthetic fork can replace the stripped real `agents/spawn`
  with properly-paired messages that maintain wire alternation.
  """
  @spec extract_clone_instruction([term()]) :: {[term()], String.t() | nil}
  def extract_clone_instruction(messages) do
    case List.last(messages) do
      {:assistant, %Assistant{parts: parts}} ->
        clone =
          Enum.find(parts, fn
            %Part.ToolUse{name: "agents/spawn"} -> true
            _ -> false
          end)

        if clone do
          {Enum.drop(messages, -1), Map.get(clone.arguments, "query", "")}
        else
          {messages, nil}
        end

      _ ->
        {messages, nil}
    end
  end

  @doc """
  Append a synthetic `agents/spawn` fork to the message list
  so the subagent sees a coherent origin story with proper
  wire alternation:

    * assistant with an `agents/spawn` `Part.ToolUse` (empty arguments)
    * tool with a `Part.ToolResult` pairing the synthetic id
    * assistant acknowledging the fork

  The acknowledgement tells the clone its name and spawn
  depth (its system message is inherited verbatim from the
  parent, so this user-visible notice is the only place to
  state the clone's true identity/depth).

  Returns `{messages_with_fork, next_index}`.
  """
  @spec build_clone_fork([term()], non_neg_integer(), String.t(), non_neg_integer()) ::
          {[term()], non_neg_integer()}
  def build_clone_fork(messages, next_index, child_name, depth) do
    clone_id = "subagent-clone-#{next_index}"

    assistant_clone =
      {:assistant,
       %Assistant{
         index: next_index,
         parts: [%Part.ToolUse{id: clone_id, name: "agents/spawn", arguments: %{}}],
         timestamp: DateTime.utc_now(),
         api_logs: []
       }}

    tool_result =
      {:tool,
       %Tool{
         index: next_index + 1,
         parts: [
           %Part.ToolResult{
             tool_call_id: clone_id,
             name: "agents/spawn",
             content:
               "Subagent spawned successfully. You are now the delegated clone, " <>
                 "named \"#{child_name}\", at depth #{depth}.",
             arguments: %{},
             is_error: false
           }
         ],
         timestamp: DateTime.utc_now(),
         api_logs: []
       }}

    assistant_ack =
      {:assistant,
       %Assistant{
         index: next_index + 2,
         parts: [
           %Part.Text{
             text:
               "Understood. I am the clone, named \"#{child_name}\", at depth " <>
                 "#{depth}. What is my task?"
           }
         ],
         timestamp: DateTime.utc_now(),
         api_logs: []
       }}

    {
      messages ++ [assistant_clone, tool_result, assistant_ack],
      next_index + 3
    }
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
