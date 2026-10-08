defmodule Nest.Agents.Agent.PeerQuery do
  @moduledoc """
  The "send a peer a chat message and wait for its reply" wait, shared by
  the synchronous `agents-query` dispatch and the async waiter.

  Unlike `agents-spawn` (a child the parent tracks in `pending_children`),
  the queried agent is independent and has no relationship to the caller,
  so there is no `:child_completed` cast to wait on. Instead we subscribe
  to the target's PubSub topic, trigger its turn with `Agents.chat/3`, and
  watch for the idle `:chat_status` broadcast. We capture the target's
  message count BEFORE sending so the first idle we see is only accepted
  once a NEW assistant message (index >= pre_count) exists.

  ## Known limitation: the pre-count guard does not cover a busy peer

  The guard above only holds when the target was idle and the query's own
  turn is the next thing it does. For a **busy** target the query is now
  *queued* rather than dropped (issue #15 changed that), but the target's
  *own* turn still ends by publishing a transient `:idle`: the turn-end
  inbox drain broadcasts `streaming → idle → streaming` before the queued
  query starts its new turn (`Turn.run/5` broadcasts the status, then
  settles the `{:inbox_drain}` follow event). That idle arrives with the
  target's own final answer already appended at `index >= pre_count`, so
  `read_last_assistant_after/3` accepts the target's answer to its
  *previous* turn as the reply to this query; the target then answers the
  query too, but nobody reads that answer. The same happens while the
  target is compacting and its summary lands at `index >= pre_count`.

  This module is scheduled for removal by issue #31 (agent messaging
  becomes async-only: `agents-query` will deliver a message that marks a
  reply obligation, and the answer will arrive as an addressed
  `agents-send` message). Until that lands, treat the guard above as
  unreliable for a busy target. `agents-wait`
  (`Nest.Agents.Agent.WaitLoop`) does not share the problem: it re-reads
  the target's own status rather than trusting the broadcast payload.

  The wait is tagged: a timeout, a failed read, or a turn that finished
  without text all come back as errors with distinct reasons, never as a
  successful empty result.

  ## Parent monitoring

  The async waiter passes its calling agent's pid. If that agent goes away
  mid-wait the wait ends immediately with `:parent_down`, so the waiter can
  exit quietly instead of blocking until its timeout. The blocking path
  passes `nil` and never monitors anyone.
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.WaitBudget
  alias Nest.Messages.Part

  @type result ::
          {:ok, String.t()}
          | {:error,
             {:timeout, timeout()}
             | :no_text
             | {:read_failed, term()}
             | {:chat, term()}
             | {:not_found, term()}}
          | :parent_down

  @doc """
  Send `prompt` to `target` and wait for its reply. Returns `{:ok, text}`
  on success, a tagged `{:error, reason}` on failure, or `:parent_down`
  when `parent_pid` (if given) dies mid-wait.
  """
  @spec run(String.t(), String.t(), String.t(), timeout(), pid() | nil) :: result()
  def run(space_id, target, prompt, timeout, parent_pid \\ nil) do
    parent = if parent_pid, do: {Process.monitor(parent_pid), parent_pid}
    # One deadline for the whole query, started before the message read and
    # the chat, so the read/setup time counts against `timeout` too.
    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      query_peer(space_id, target, prompt, timeout, parent, deadline)
    after
      if parent, do: Process.demonitor(elem(parent, 0), [:flush])
    end
  end

  defp query_peer(space_id, target, prompt, timeout, parent, deadline) do
    case Nest.Agents.get_messages(space_id, target) do
      {:ok, messages} ->
        topic = Broadcasts.topic(space_id, target)
        Phoenix.PubSub.subscribe(Nest.PubSub, topic)

        try do
          case Nest.Agents.chat(space_id, target, prompt) do
            :ok -> wait_for_idle(space_id, target, length(messages), deadline, timeout, parent)
            {:error, reason} -> {:error, {:chat, reason}}
          end
        after
          Phoenix.PubSub.unsubscribe(Nest.PubSub, topic)
        end

      {:error, reason} ->
        {:error, {:not_found, reason}}
    end
  end

  # The wait is bounded by a wall-clock deadline, not a message count:
  # the target's own streaming traffic (`chat:delta`, `chat:message`,
  # `shell:jobs`, ...) lands in this mailbox too, so counting messages
  # would let a chatty target exhaust a long timeout in seconds.
  # Unrelated messages are drained without touching the deadline; only
  # elapsed time ends the wait.
  defp wait_for_idle(space_id, target, pre_count, deadline, timeout, parent) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("agents-query: target did not go idle within #{timeout}ms")
      {:error, {:timeout, timeout}}
    else
      receive do
        {:chat_status, %{status: "idle"}} ->
          case read_last_assistant_after(space_id, target, pre_count) do
            :pending -> wait_for_idle(space_id, target, pre_count, deadline, timeout, parent)
            reply -> reply
          end

        {:DOWN, ref, :process, pid, _reason} when parent == {ref, pid} ->
          :parent_down

        _other ->
          wait_for_idle(space_id, target, pre_count, deadline, timeout, parent)
      after
        min(WaitBudget.wait_slice_ms(), remaining) ->
          wait_for_idle(space_id, target, pre_count, deadline, timeout, parent)
      end
    end
  end

  # The target's newest assistant message that arrived after the
  # query was sent (index >= pre_count). Returns `:pending` when the
  # turn hasn't produced one yet (so the idle wait keeps going),
  # `{:ok, text}` when it produced text, and `{:error, :no_text}` when it
  # finished with an assistant message that carries no text parts.
  defp read_last_assistant_after(space_id, target, pre_count) do
    case Nest.Agents.get_messages(space_id, target) do
      {:ok, messages} ->
        messages
        |> Enum.reverse()
        |> Enum.find_value(:pending, fn
          {:assistant, %{index: idx, parts: parts}} when idx >= pre_count ->
            assistant_reply(parts)

          _ ->
            nil
        end)

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  # A reply of `""` (an assistant message with no text parts) is not a
  # successful answer: report it as `{:error, :no_text}` so the tool
  # surfaces an explicit error instead of an empty result.
  defp assistant_reply(parts) do
    case assistant_text(parts) do
      "" -> {:error, :no_text}
      text -> {:ok, text}
    end
  end

  defp assistant_text(parts) do
    Enum.map_join(parts, fn
      %Part.Text{text: text} -> text
      _ -> ""
    end)
  end
end
