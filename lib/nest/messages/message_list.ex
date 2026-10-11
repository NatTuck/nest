defmodule Nest.Messages.MessageList do
  @moduledoc """
  Pure functions on message lists. Shared by the compactor and
  subagent paths so they can use the same utilities without
  importing turn-internal functions.
  """

  alias Nest.LLM.Client
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.User

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
    case unpaired_tail_tool_uses(messages) do
      [] -> synthesize_clone_fork(messages, next_index, child_name, depth)
      tool_uses -> answer_clone_fork(messages, next_index, child_name, depth, tool_uses)
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

  A trailing message whose wire role is already `user` followed by an
  `incoming` user message would be two consecutive `user` roles. That
  tail is either a `{:tool, _}` result (wire role `user`) — the common
  case at the turn-boundary inbox delivery (issue #15), where a queued
  message is appended mid-turn onto a just-answered tool call — or a
  `{:user, _}` whose turn was interrupted before any assistant response
  was committed. In both cases the bridge returns the assistant
  acknowledgement alone (`idle_bridge_ack(:live)`) to restore
  alternation.

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

        repair_messages(missing, incoming)

      {wire_user, _} when wire_user in [:user, :tool] ->
        if match?({:user, _}, incoming), do: [idle_bridge_ack(:live)], else: []

      _ ->
        []
    end
  end

  @doc """
  The `Part.ToolUse` structs on the trailing assistant message, or `[]`
  when the list does not end on an assistant tool call.

  At the tail every returned `tool_use` is unanswered by construction:
  the message that would carry its result is itself a `{:tool, _}` and
  each `{:tool, _}` is immediately preceded by the assistant it answers.
  Shared by the fork path, the load-time interrupted-turn heal, and the
  run-time tool-worker recovery.
  """
  @spec unpaired_tail_tool_uses([term()]) :: [Part.ToolUse.t()]
  def unpaired_tail_tool_uses(messages) do
    case List.last(messages) do
      {:assistant, %Assistant{parts: parts}} ->
        for %Part.ToolUse{} = tool_use <- parts || [], do: tool_use

      _ ->
        []
    end
  end

  @doc """
  A `{:tool, _}` answering every given `tool_use` with the canonical
  `is_error: true` "interrupted" result, or `nil` for an empty list.

  Used when a turn ends without producing a result: the load path heals
  the persisted tail before going `:idle`, and the run-time path feeds
  the error back to the model so the turn can continue.
  """
  @spec interrupted_tool_result([Part.ToolUse.t()]) :: {:tool, Tool.t()} | nil
  def interrupted_tool_result([]), do: nil

  def interrupted_tool_result(tool_uses) do
    List.first(repair_messages(tool_uses, :no_incoming))
  end

  @doc """
  Build the repair messages for a set of unpaired `Part.ToolUse`
  structs followed by `incoming`.

  Returns a `{:tool, _}` carrying one `is_error: true` result per
  missing `tool_use`, plus an assistant acknowledgement when
  `incoming` is a user message (wire role `user`). Returns `[]`
  when there is nothing to repair. Shared by the live append
  bridge (`pairing_bridge/2`) and the offline repair tool so the
  synthetic shape and wording stay identical.
  """
  @spec repair_messages([Part.ToolUse.t()], term()) :: [term()]
  def repair_messages([], _incoming), do: []

  def repair_messages(missing_tool_uses, incoming) do
    tool =
      {:tool, %Tool{parts: Enum.map(missing_tool_uses, &unpaired_tool_result/1), api_logs: []}}

    if match?({:user, _}, incoming) do
      [tool, repair_ack()]
    else
      [tool]
    end
  end

  @doc """
  The `is_error: true` result answering an interrupted
  `Part.ToolUse`. The tool name is preserved so the repaired
  result is shaped like a real one.
  """
  @spec unpaired_tool_result(Part.ToolUse.t()) :: Part.ToolResult.t()
  def unpaired_tool_result(%Part.ToolUse{id: id, name: name}) do
    %Part.ToolResult{
      tool_call_id: id,
      name: name,
      content: "Tool call interrupted before completion (repaired).",
      arguments: %{},
      is_error: true
    }
  end

  @doc """
  The synthetic assistant acknowledgement inserted after a repair
  tool result when the next message is a user turn, so the wire
  does not carry two consecutive `user` roles.
  """
  @spec repair_ack() :: term()
  def repair_ack do
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
  The synthetic assistant acknowledgement that closes an idle
  sequence which would otherwise end on a `user` wire role.

  An idle agent must never end on a user message: the next user turn
  would then need the live-path bridge (`Repair.classify_live/2`). Both
  the compaction commit (`Turn.Commit.active_segment/6`) and the
  load-time heal (`Repair.classify_load/1`) append this ack so the
  invariant is enforced upstream and the turn-opening append is clean.

  The wording is case-specific so the ack reads sensibly in context:

    * `:compaction` — a compaction just finished;
    * `:load` — we were interrupted before an assistant response;
    * `:live` — the alternation bridge (`MessageList.pairing_bridge/2`),
      where nothing was interrupted: a second user message simply
      follows a user tail. The turn-boundary inbox delivery (issue #15)
      appends exactly that shape mid-turn.

  Same shape as `repair_ack/0`: an assistant text message with no
  `index` (the append path stamps it) and no `api_logs`.
  """
  @spec idle_bridge_ack(atom()) :: term()
  def idle_bridge_ack(:compaction) do
    build_idle_bridge_ack("Compaction complete. What would you like to do next?")
  end

  def idle_bridge_ack(:load) do
    build_idle_bridge_ack(
      "We were interrupted before I could respond. Ready to continue when you are."
    )
  end

  def idle_bridge_ack(:live) do
    build_idle_bridge_ack("Okay, continuing from here.")
  end

  # The tag set is closed (`:compaction`, `:load`, `:live`). An unknown tag is
  # a programming error, so fail loudly with a clear message rather than
  # quietly picking a default wording for a case nobody thought about.
  def idle_bridge_ack(other) do
    raise ArgumentError, "unknown idle_bridge_ack kind: #{inspect(other)}"
  end

  defp build_idle_bridge_ack(text) do
    {:assistant, %Assistant{parts: [%Part.Text{text: text}], api_logs: []}}
  end

  @doc """
  Build the synthetic `{:tool, _}` that answers a batch moved to the
  background (issue #36).

  Every call in the batch is answered with an `is_error: false` result
  whose wording says the call was backgrounded and that its result will
  arrive later as a message. Each result also states the call's own
  declared timeout bound (decision D4): the tool's timeout *is* the
  promise's bound, so the model knows the call is still running and when
  to expect its result rather than waiting on a call that has not
  finished.

  Each result carries `state: "backgrounded"` so the panel can badge it
  as a call whose result has not arrived, rather than reading the
  `is_error: false` flag as a success the data does not support.

  Returns `nil` for an empty batch (nothing to answer), like
  `interrupted_tool_result/1`. Accepts the `Part.ToolUse` structs of the
  pending assistant message and the `ToolCall` structs of the preflight
  batch alike — both carry the `id`/`name`/`arguments` a result needs.
  """
  @spec backgrounded_tool_result([Part.ToolUse.t() | ToolCall.t()]) :: {:tool, Tool.t()} | nil
  def backgrounded_tool_result([]), do: nil

  def backgrounded_tool_result(calls) do
    parts = Enum.map(calls, &backgrounded_result/1)
    {:tool, %Tool{parts: parts, api_logs: []}}
  end

  defp backgrounded_result(%{id: id, name: name, arguments: arguments}) do
    %Part.ToolResult{
      tool_call_id: id,
      name: name,
      content: backgrounded_text(name, arguments),
      arguments: arguments || %{},
      is_error: false,
      # The panel must not badge this as a success: the call has produced no
      # result yet, and its real one arrives later as a message. `is_error`
      # stays false because the model's wire encoding reads it, and a
      # backgrounded call is not an error.
      state: "backgrounded"
    }
  end

  defp backgrounded_text(name, arguments) do
    "The #{name} call was moved to the background so your message could be " <>
      "delivered now; its result will arrive later as a message. " <>
      backgrounded_bound(arguments)
  end

  # The model declared the call's own timeout in its arguments (the
  # `shell-cmd` tool's `timeout`, in seconds). State it: the bound is the
  # promise's, and the model should not expect a result before it.
  defp backgrounded_bound(%{"timeout" => seconds}) when is_integer(seconds) do
    "The call's own timeout bound is #{seconds} seconds; it is killed at that bound."
  end

  defp backgrounded_bound(_arguments) do
    "The call declared no timeout of its own, so it runs under its tool's default bound."
  end

  @doc """
  The synthetic assistant acknowledgement that follows a backgrounded
  batch's synthetic result (issue #36).

  Same family as `idle_bridge_ack/1`: an assistant text message with no
  `index` (the append path stamps it) and no `api_logs`. It tells the
  model the call is running in the background and its result will arrive
  as a message, so the turn reads coherently while the batch finishes.
  """
  @spec backgrounded_ack() :: term()
  def backgrounded_ack do
    build_idle_bridge_ack(
      "Understood. The call is running in the background; I'll continue when its " <>
        "result arrives as a message."
    )
  end

  @lost_promise_key "backgrounded_lost_ids"
  @fulfilled_promise_key "backgrounded_fulfilled_ids"

  @doc """
  The tool-result parts of `messages` that still promise a result which has not
  arrived (issue #36): every result `backgrounded_tool_result/1` built carries
  `state: "backgrounded"`.

  The promise is kept only while the batch's entry is live in
  `Machine.Work.backgrounded`, which dies with the process. A *restored*
  transcript therefore still promises a message that can never come, so
  `Repair.classify_load/1` records the loss (`tag_lost_promises/2`) — and a
  promise an existing record already names is not reported again, which is what
  makes the load heal idempotent (`Init.LoadHeal.refresh/1` re-classifies the
  tail before appending).

  A promise whose result *did* arrive is not reported either: the notice the
  result was delivered as carries the ids it answers (`fulfilled_metadata/1`,
  written onto the delivered message by `Inbox.build_drained_message/3`), so a
  later load tells the two apart instead of recording a loss for a call whose
  result arrived.
  """
  @spec backgrounded_results([term()]) :: [Part.ToolResult.t()]
  def backgrounded_results(messages) do
    recorded = promise_ids(messages, @lost_promise_key)
    fulfilled = promise_ids(messages, @fulfilled_promise_key)

    for {:tool, %Tool{parts: parts}} <- messages,
        %Part.ToolResult{state: "backgrounded"} = result <- parts || [],
        result.tool_call_id not in recorded,
        result.tool_call_id not in fulfilled,
        do: result
  end

  @doc """
  The metadata that marks the tool calls a delivered notice answers as
  fulfilled (issue #36).

  `ids` are the calls a backgrounded batch's *result* answered; the metadata
  rides the message the drain appends, so `backgrounded_results/1` does not
  report those promises as lost on a later load. Empty for no ids, so an
  ordinary delivery carries no marker at all.
  """
  @spec fulfilled_metadata([String.t()]) :: map()
  def fulfilled_metadata([]), do: %{}
  def fulfilled_metadata(ids), do: %{@fulfilled_promise_key => ids}

  @doc """
  Tag a lost-promise record with the tool call ids it voids, so
  `backgrounded_results/1` does not report them again.

  The tag rides the record's assistant message `metadata`, which persists and
  round-trips exactly like any other message metadata.
  """
  @spec tag_lost_promises([term()], [String.t()]) :: [term()]
  def tag_lost_promises(record, ids) do
    Enum.map(record, fn
      {:assistant, %Assistant{} = assistant} ->
        {:assistant, %{assistant | metadata: put_lost_ids(assistant.metadata, ids)}}

      other ->
        other
    end)
  end

  defp put_lost_ids(metadata, ids) when is_map(metadata),
    do: Map.put(metadata, @lost_promise_key, ids)

  defp put_lost_ids(_metadata, ids), do: %{@lost_promise_key => ids}

  # Every id named under `key` by any message's metadata. Any role, because the
  # two markers are written by different paths: the lost record is an assistant
  # (`tag_lost_promises/2`) and the fulfilled marker rides the delivered user
  # message (`fulfilled_metadata/1`). A message whose metadata is not a map
  # names nothing.
  defp promise_ids(messages, key) do
    messages
    |> Enum.flat_map(fn
      {_role, %{metadata: %{} = metadata}} -> List.wrap(metadata[key])
      _ -> []
    end)
    |> MapSet.new()
  end

  @doc """
  The synthetic user message inserted between two consecutive
  assistant wire roles, so the sequence alternates again.
  """
  @spec continuation_prompt() :: term()
  def continuation_prompt do
    {:user,
     %User{
       parts: [
         %Part.Text{
           text:
             "An earlier assistant turn did not complete cleanly. " <>
               "Please continue from here."
         }
       ]
     }}
  end

  defp answered_tool_ids({:tool, %Tool{parts: parts}}) do
    for %Part.ToolResult{tool_call_id: id} <- parts || [], do: id
  end

  defp answered_tool_ids(_incoming), do: []

  @doc """
  The text of the list's trailing assistant message — the agent's
  "stop message", the final thing it said before its turn ended.

  Returns `""` when the list does not end on an assistant message (or
  that message has no text parts). Shared by `Turn.Terminal` (the
  parent's `:child_completed` payload) and `Agent.WaitLoop` (reading a
  peer's final message across processes), so both report exactly the
  same content for the same sequence.
  """
  @spec last_assistant_text([term()]) :: String.t()
  def last_assistant_text(messages) do
    case List.last(messages) do
      {:assistant, %Assistant{parts: parts}} when is_list(parts) -> Client.text_from_parts(parts)
      _ -> ""
    end
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
