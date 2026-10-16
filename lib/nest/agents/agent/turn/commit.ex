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

  `preserve` is the agent's own content for the summary message, written by
  the machinery rather than by the compactor (see `summary_body/4`).
  """
  @spec active_segment(
          Agent.t(),
          String.t(),
          String.t() | nil,
          Agent.Machine.entry() | nil,
          non_neg_integer(),
          non_neg_integer(),
          String.t() | nil
        ) :: {[term()], tuple()}
  def active_segment(
        state,
        summary_text,
        preserve,
        carried_entry,
        marker_index,
        archived_count,
        system_prompt
      ) do
    now = DateTime.utc_now()
    archived_messages = state.chat_state.messages || []

    # The size of what this compaction replaces, computed once: it is what the
    # marker records and what the summary message reports, so one event cannot
    # report two numbers.
    tokens_compacted = Estimator.estimate_messages(archived_messages)

    summary_user =
      {:user,
       %User{
         parts: [
           %Part.Text{
             text: summary_body(summary_text, preserve, tokens_compacted, marker_index)
           }
         ],
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
        tokens_compacted,
        Estimator.estimate_messages(new_messages)
      )

    {new_messages, marker}
  end

  # The summary message's body: what this compaction replaced, the agent's own
  # `preserve` text verbatim, the compactor's summary, and where the archived
  # conversation is still readable.
  #
  # `preserve` sits here rather than in the compactor's output on purpose. The
  # request tells the compactor not to duplicate it, and the machinery writes
  # it, so the material an agent wrote to survive the compaction survives it
  # whatever the compactor returns.
  #
  # `preserve` is nil or non-blank by the time it arrives (`Response`'s argument
  # validation normalizes a blank *or whitespace-only* one away), and a blank
  # section is dropped either way — a direct caller of this pure builder gets
  # the same treatment. An empty `summary_text` cannot reach here (the commit
  # validates the summary first).
  defp summary_body(summary_text, preserve, tokens_compacted, marker_index) do
    [
      "Summary of previous conversation (compacted from #{tokens_compacted} tokens):",
      preserve,
      summary_text,
      archive_pointer(marker_index)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  # A section that is nil, empty, or nothing but whitespace would render as an
  # empty section between two separators.
  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""

  # Names the archived range in the form `agents-history` takes, so a reader who
  # finds the summary wanting is one call from the rest of it. The range is
  # `0..marker_index - 1`: indices are contiguous from 0, and the marker row
  # itself sits at `marker_index`.
  defp archive_pointer(marker_index) do
    "The conversation before this compaction is still readable with " <>
      "`agents-history` (start_index 0, length #{marker_index})."
  end

  @doc """
  Append the carried entry's messages to the new active segment.

  `{:compact_resume, _, _}` carries none: a `context-compact` call and its
  synthetic result are persisted *before* the compaction request, so they
  belong to the segment this compaction archives. The entry exists to resume
  generation on the far side of the commit.
  """
  @spec append_entry_tail([term()], Agent.Machine.entry() | nil) :: [term()]
  def append_entry_tail(new_messages, {:user_message, msg}), do: new_messages ++ [{:user, msg}]
  def append_entry_tail(new_messages, {:tool_call, msg, _, _}), do: new_messages ++ [msg]
  def append_entry_tail(new_messages, {:compact_resume, _, _}), do: new_messages
  def append_entry_tail(new_messages, {:assistant_response, msg, _, _}), do: new_messages ++ [msg]
  def append_entry_tail(new_messages, _other), do: new_messages

  # A carried assistant was produced against the pre-compaction context,
  # so its provider `usage` no longer anchors the active segment. Drop the
  # struct field (the api_log still carries the response).
  defp drop_pre_compaction_usage({:assistant, %Assistant{} = assistant}) do
    {:assistant, %{assistant | usage: nil}}
  end

  defp drop_pre_compaction_usage(message), do: message

  # An idle agent must never end on a `user` wire role. A carried `user_message`
  # ends on one, and with no carried entry the segment ends on the summary user
  # message — both of which would make the next user turn need the live-path
  # bridge.
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
