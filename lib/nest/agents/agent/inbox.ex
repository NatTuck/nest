defmodule Nest.Agents.Agent.Inbox do
  @moduledoc """
  Async agent-to-agent inbox for the `Agent` GenServer.

  An `agents-send` tool call hands a message to the target agent's
  GenServer (`Agent.deliver_message/3` → `handle_delivery/3`).

    * **Idle target** — the message (plus anything already queued) is
      combined into one user message and drained through the turn
      executor (`Nest.Agents.Agent.Turn.drain_inbox/1`), the single drain
      path.
    * **Busy target** (`:streaming`, `:executing_tools`, `:compacting`) —
      the message is queued on `state.live.inbox`. When the target next
      goes idle the machine's `:idle` transition emits the `:drain_inbox`
      action, which drains every queued entry into a single user message.
    * **Broken target** (`:model_missing`, `:needs_repair`,
      `:context_overflow`, `:compaction_failed`,
      `:compaction_loop_detected`) — the sender gets an error and
      nothing is queued.

  A combined message over `Config.configured_async_message_max_tokens/0`
  is written to the agent's scratch dir and replaced by a short pointer
  telling the agent how many messages there were and where to read them.

  The inbox is in-memory (`ChatState.Live`), so a BEAM restart drops
  undrained messages. It is capped at `@max_inbox_size` so a runaway
  producer cannot grow it without bound.
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
  # start a turn.
  @busy_statuses [:streaming, :executing_tools, :compacting]

  # Hard cap on queued messages. When full the sender gets an
  # `:inbox_full` error and nothing is queued.
  @max_inbox_size 100

  @type entry :: %{from: String.t(), content: String.t(), timestamp: DateTime.t()}

  @doc """
  `handle_call/3` body for `Agent.deliver_message/3`.

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

      status in @busy_statuses ->
        state = state |> enqueue(sender, content) |> broadcast()
        {:reply, {:ok, :queued}, state}

      status == :idle ->
        state = enqueue(state, sender, content)
        {state, result} = Turn.drain_inbox(state)
        {:reply, {:ok, result}, state}

      true ->
        {:reply, {:error, {:status, status}}, state}
    end
  end

  @doc """
  JSON-safe view of the queued entries, for the wire (channel/status)
  and tests.
  """
  @spec serialize([entry()]) :: [map()]
  def serialize(entries) do
    Enum.map(entries, fn entry ->
      %{
        "from" => entry.from,
        "content" => entry.content,
        "timestamp" => DateTime.to_iso8601(entry.timestamp)
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

  defp enqueue(state, sender, content) do
    entry = %{from: sender, content: content, timestamp: DateTime.utc_now()}
    %{state | live: %{state.live | inbox: state.live.inbox ++ [entry]}}
  end

  defp broadcast(state) do
    Broadcasts.inbox(state, serialize(state.live.inbox))
    state
  end

  defp combine(entries) do
    Enum.map_join(entries, "\n\n", fn entry ->
      "[Message from agent \"#{entry.from}\"]\n#{entry.content}"
    end)
  end

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
    "You have 1 queued message from another agent. It was too large to " <>
      "include inline and was saved to #{path}. Read that file to see it."
  end

  defp pointer(n, path) do
    "You have #{n} queued messages from other agents. They were too large to " <>
      "include inline and were saved to #{path}. Read that file to see them."
  end
end
