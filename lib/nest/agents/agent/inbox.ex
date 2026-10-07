defmodule Nest.Agents.Agent.Inbox do
  @moduledoc """
  The `Agent`'s queued-message inbox.

  Two producers queue here:

    * an `agents-send` tool call from another agent
      (`Agent.deliver_message/3` → `handle_delivery/3`), recorded with
      `kind: :agent`, and
    * a human chat message that arrived while the agent was busy
      (`Agent.chat/4` → `Callbacks.chat_or_queue/4` →
      `enqueue_user_message/4`), recorded with `kind: :user`.

  An entry is `%{from, content, timestamp, kind, mode}`. `content` is
  stored **verbatim** (no `[mode: ...]` prefix — that is added when the
  entry is delivered) and `mode` is the human's requested mode, always
  `nil` for an `agents-send` entry.

  ## Disposition

    * **Idle target** — the message (plus anything already queued) is
      combined into one user message and drained through the turn
      executor (`Nest.Agents.Agent.Turn.drain_inbox/1`), the single drain
      path.
    * **Busy target** (`:streaming`, `:executing_tools`, `:compacting`) —
      the message is queued on `state.live.inbox`. The machine drains it at
      the next turn boundary: `Transitions.iterate/1` emits the
      `:drain_inbox` action from `:generating`/`:chat` once the wire
      sequence is complete and nothing is in flight (issue #15), and
      anything still queued when the target reaches `:idle` is drained by
      the `:idle` transition. Either way every queued entry is combined
      into a single user message.
    * **Broken target** (`:model_missing`, `:needs_repair`,
      `:context_overflow`, `:compaction_failed`,
      `:compaction_loop_detected`) — `handle_delivery/3` replies with an
      error and nothing is queued; a human message is dropped, since the
      channel has already told the operator why.

  ## Delivery

  `combine/1` labels each entry by kind: an `agents-send` entry keeps
  `[Message from agent "<from>"]`, a queued human message reads
  `[Message from the user "<from>"]`, and an unknown sender (`nil`) drops
  the quoted name rather than putting `nil` in the prompt. A combined
  message over `Config.configured_async_message_max_tokens/0` is written to
  the agent's scratch dir and replaced by a short pointer telling the agent
  how many messages there were and where to read them.

  ## One mode per delivery

  Every queued entry is combined into ONE user message, so the batch runs
  in one mode: the most recent human-sourced entry that carries a mode wins
  (`drain_mode/1`), and `nil` leaves the agent's current mode unchanged.
  The executor applies the winning mode when it drains — never when the
  entry is queued, because `state.live.mode` feeds `ctx.mode`/`ctx.caps`,
  which are rebuilt on every settle; setting it on arrival would re-resolve
  the caps of the *ongoing* turn's remaining tool calls.

  The inbox is in-memory (`ChatState.Live`), so a BEAM restart drops
  undrained messages. `@max_inbox_size` bounds a runaway *agent* producer; a
  human message is queued even when the cap is reached rather than silently
  dropped, so the human queue is unbounded (self-limited by human typing —
  nothing in the app rate-limits it) and each enqueue rebroadcasts the whole
  serialized list.
  """

  alias Nest.Agents.Agent
  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.Config
  alias Nest.Agents.Agent.Machine
  alias Nest.Agents.Agent.Turn
  alias Nest.Tokens.Estimator

  require Logger

  # Statuses during which an incoming message must queue rather than
  # start a turn. `Machine.status_for/1` maps `:stopping` to `:streaming`,
  # so a message that arrives during a stop queues here and the stop
  # path's `{:drain_inbox}` delivers it.
  @busy_statuses [:streaming, :executing_tools, :compacting]

  # Hard cap on queued agent-sourced messages. When full the sender gets
  # an `:inbox_full` error and nothing is queued.
  @max_inbox_size 100

  @type kind :: :agent | :user

  @type entry :: %{
          from: String.t() | nil,
          content: String.t(),
          timestamp: DateTime.t(),
          kind: kind(),
          mode: String.t() | nil
        }

  @doc """
  True for the statuses where an incoming message queues instead of starting
  a turn. Shared with `Callbacks.chat_or_queue/4` so "busy" has one
  definition.
  """
  @spec busy_status?(atom()) :: boolean()
  def busy_status?(status), do: status in @busy_statuses

  @doc """
  `handle_call/3` body for `Agent.deliver_message/3` (the `agents-send`
  path).

  Returns the GenServer reply tuple:
    * `{:ok, :delivered}` — the target was idle; a turn started.
    * `{:ok, :queued}` — the target was busy (or the turn could not
      start) and the message is queued.
    * `{:error, reason}` — the target is in a broken state or the inbox
      is full.
  """
  @spec handle_delivery(Agent.t(), String.t(), String.t()) ::
          {:reply, {:ok, :delivered | :queued} | {:error, term()}, Agent.t()}
  def handle_delivery(state, sender, content) do
    status = Machine.status_for(state.live.machine)

    cond do
      length(state.live.inbox) >= @max_inbox_size ->
        {:reply, {:error, :inbox_full}, state}

      busy_status?(status) ->
        state = state |> put_entry(sender, content, :agent, nil) |> broadcast()
        {:reply, {:ok, :queued}, state}

      status == :idle ->
        state = put_entry(state, sender, content, :agent, nil)
        {state, result} = Turn.drain_inbox(state)
        {:reply, {:ok, result}, state}

      true ->
        {:reply, {:error, {:status, status}}, state}
    end
  end

  @doc """
  Queue a human chat message on the agent's own inbox.

  Called by `Callbacks.chat_or_queue/4` when the agent is busy. `from` is
  the sender identity (the channel passes the socket's username; `nil` is
  allowed), `content` is stored verbatim, and `mode` is the human's
  requested mode (`nil` when the caller picked none). Broadcasts the new
  inbox and returns the updated state.

  Unlike `handle_delivery/3` this never refuses: the sender is a human and
  the cap exists to bound a runaway *agent* producer, so a human message is
  queued even when the cap is reached instead of being silently dropped.
  """
  @spec enqueue_user_message(Agent.t(), String.t() | nil, String.t(), String.t() | nil) ::
          Agent.t()
  def enqueue_user_message(state, from, content, mode) do
    state |> put_entry(from, content, :user, mode) |> broadcast()
  end

  @doc """
  The mode a drained batch runs in: the most recent human-sourced entry
  that carries a mode wins, and `nil` (no such entry) leaves the agent's
  current mode unchanged. The winner is the *requested* mode; the executor's
  `:drain_inbox` resolves it against the vocation (falling back to the
  vocation's default mode) before storing it, exactly as an idle chat turn
  resolves its request.
  """
  @spec drain_mode([entry()]) :: String.t() | nil
  def drain_mode(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{kind: :user, mode: mode} when is_binary(mode) -> mode
      _ -> nil
    end)
  end

  @doc """
  JSON-safe view of the queued entries, for the wire (channel/status)
  and tests. `"kind"` is `"agent"` or `"user"`; `"mode"` is a string or
  `nil`.
  """
  @spec serialize([entry()]) :: [map()]
  def serialize(entries) do
    Enum.map(entries, fn entry ->
      %{
        "from" => entry.from,
        "content" => entry.content,
        "timestamp" => DateTime.to_iso8601(entry.timestamp),
        "kind" => Atom.to_string(entry.kind),
        "mode" => entry.mode
      }
    end)
  end

  @doc """
  Combine queued entries and, when over the async-message cap, offload the
  text to the agent scratch dir. Returns the content string to deliver.
  Used by the turn executor's `:drain_inbox` action.
  """
  @spec combine_and_offload([entry()], Agent.t()) :: String.t()
  def combine_and_offload(entries, state) do
    offload(combine(entries), entries, state)
  end

  # ---- private ----

  # `from`/`mode` are normalized here, the single write point, so a malformed
  # payload can never put a number/map on the wire (`serialize/1`'s contract is
  # string-or-null for both).
  defp put_entry(state, from, content, kind, mode) do
    entry = %{
      from: if(is_binary(from), do: from, else: nil),
      content: content,
      timestamp: DateTime.utc_now(),
      kind: kind,
      mode: if(is_binary(mode), do: mode, else: nil)
    }

    %{state | live: %{state.live | inbox: state.live.inbox ++ [entry]}}
  end

  defp broadcast(state) do
    Broadcasts.inbox(state, serialize(state.live.inbox))
    state
  end

  defp combine(entries) do
    Enum.map_join(entries, "\n\n", fn entry -> "#{label(entry)}\n#{entry.content}" end)
  end

  # The LLM-facing label for one entry. A missing or blank sender drops the
  # quoted name rather than putting `nil`/`""` in the prompt.
  defp label(%{kind: :user, from: from}), do: "[Message from the user#{quoted(from)}]"
  defp label(%{from: from}), do: "[Message from agent#{quoted(from)}]"

  defp quoted(from) when is_binary(from) and from != "", do: " \"#{from}\""
  defp quoted(_from), do: ""

  # Over the configured cap, write the full combined text to the agent's
  # scratch dir and return a pointer. If the write fails, fall back to
  # the full text so no messages are lost.
  defp offload(content, entries, state) do
    if Estimator.estimate(content) > Config.configured_async_message_max_tokens() do
      case Overflow.write(content, %{tmp_path: state.tmp_path}, "agent-inbox", "txt") do
        nil -> content
        path -> pointer(length(entries), path)
      end
    else
      content
    end
  end

  defp pointer(1, path) do
    "You have 1 queued message. It was too large to " <>
      "include inline and was saved to #{path}. Read that file to see it."
  end

  defp pointer(n, path) do
    "You have #{n} queued messages. They were too large to " <>
      "include inline and were saved to #{path}. Read that file to see them."
  end
end
