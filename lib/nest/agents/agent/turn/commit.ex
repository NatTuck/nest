defmodule Nest.Agents.Agent.Turn.Commit do
  @moduledoc """
  Pure builders for the post-compaction active segment.

  `Turn.Executor` performs the compaction commit's database writes; this
  module builds the messages and marker it writes. Splitting the pure
  shaping out keeps the executor focused on effects and keeps the
  segment layout (`rebuilt system?`, `summary_user`, carried tail,
  usage drop) in one exhaustively-testable place.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.Compaction.Marker
  alias Nest.Agents.Agent.SystemPrompt
  alias Nest.Messages.Assistant
  alias Nest.Messages.MessageList
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.User
  alias Nest.Tokens.Estimator

  require Logger

  @doc """
  Build `{new_active_messages, marker}` for a successful compaction.
  """
  @spec active_segment(
          Agent.t(),
          String.t(),
          Agent.Machine.entry() | nil,
          non_neg_integer(),
          non_neg_integer(),
          String.t() | nil
        ) :: {[term()], tuple()}
  def active_segment(
        state,
        summary_text,
        carried_entry,
        marker_index,
        archived_count,
        system_prompt
      ) do
    now = DateTime.utc_now()
    archived_messages = state.chat_state.messages || []

    summary_user =
      {:user,
       %User{
         parts: [%Part.Text{text: "Summary of earlier conversation:\n\n" <> summary_text}],
         timestamp: now,
         api_logs: []
       }}

    rebuilt_system = build_rebuilt_system(system_prompt, state.llm_metrics.context_limit, now)

    new_messages =
      case rebuilt_system do
        nil -> append_entry_tail([summary_user], carried_entry)
        sys -> [sys | append_entry_tail([summary_user], carried_entry)]
      end
      |> Enum.map(&drop_pre_compaction_usage/1)
      |> ensure_assistant_tail(carried_entry)

    marker =
      Marker.build_marker(
        marker_index,
        archived_count,
        state.chat_state.compaction_count + 1,
        Estimator.estimate_messages(archived_messages),
        Estimator.estimate_messages(new_messages)
      )

    {new_messages, marker}
  end

  @doc "Append the carried entry's messages to the new active segment."
  @spec append_entry_tail([term()], Agent.Machine.entry() | nil) :: [term()]
  def append_entry_tail(new_messages, {:user_message, msg}), do: new_messages ++ [{:user, msg}]
  def append_entry_tail(new_messages, {:tool_call, msg, _, _}), do: new_messages ++ [msg]
  def append_entry_tail(new_messages, {:compact_tool, [a, b], _, _}), do: new_messages ++ [a, b]
  def append_entry_tail(new_messages, {:assistant_response, msg, _, _}), do: new_messages ++ [msg]
  def append_entry_tail(new_messages, _other), do: new_messages

  # A carried assistant was produced against the pre-compaction context,
  # so its provider `usage` no longer anchors the active segment. Drop the
  # struct field (the api_log still carries the response).
  defp drop_pre_compaction_usage({:assistant, %Assistant{} = assistant}) do
    {:assistant, %{assistant | usage: nil}}
  end

  defp drop_pre_compaction_usage(message), do: message

  # An idle agent must never end on a `user` wire role. The carried
  # entry can be a user message (or a tool result, wire role `user`), and
  # with no carried entry the segment ends on the summary user message —
  # all of which would make the next user turn need the live-path bridge.
  # Close the segment with the compaction-specific assistant ack instead;
  # a carried assistant tail is already valid and gets no extra message.
  #
  # Only the `nil` carried entry (a post-turn compaction that finalizes
  # idle, or resumes a held user message) needs the ack. A carried entry
  # resumes generation (`Compaction.resume/1`), and its segment is the
  # generation request's input: it must keep ending on the user/tool tail,
  # otherwise we ship a *trailing assistant* request (Anthropic rejects a
  # prefilled assistant when thinking is enabled; DeepSeek 400s with
  # "content[].thinking ... must be passed back").
  defp ensure_assistant_tail(messages, nil) do
    if MessageList.last_wire_role(messages) == :user do
      messages ++ [MessageList.idle_bridge_ack(:compaction)]
    else
      messages
    end
  end

  defp ensure_assistant_tail(messages, _carried_entry), do: messages

  defp build_rebuilt_system(system_prompt, context_limit, now) do
    cond do
      is_nil(system_prompt) ->
        nil

      not SystemPrompt.within_size_budget?(system_prompt, context_limit) ->
        Logger.warning(
          "Compaction post-compaction dropping rebuilt system: rendered prompt exceeds " <>
            "25% safety budget for context_limit=#{context_limit}"
        )

        nil

      true ->
        {:system,
         %MsgSystem{
           parts: [%Part.Text{text: system_prompt}],
           timestamp: now,
           api_logs: [],
           metadata: nil,
           tokens: nil
         }}
    end
  end
end
