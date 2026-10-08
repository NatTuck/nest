defmodule Nest.Agents.Agent.WaitLoop do
  @moduledoc """
  Executor for the `agents-wait` tool.

  Blocks until one of a set of peer agents in the same space finishes
  its current turn (goes `:idle`), or until an explicit wall-clock
  `timeout` expires. Runs in the turn's tool worker — the same process
  `ToolLoop.execute/3` runs in — so the calling agent's GenServer stays
  free to service its own messages while the wait blocks. The wait never
  runs in the agent process.

  ## Semantics

    * An empty target list means "every other non-archived agent in
      this space" — the same set `agents-list` reports. The caller is
      never a target: it is busy running this very call.
    * Targets that are already idle are ignored; the call returns
      immediately only when *every* target is idle.
    * Otherwise it returns as soon as the first busy target goes idle,
      reporting that agent's name and the final message of its turn
      (its "stop message", read via `MessageList.last_assistant_text/1`
      — the same content `Turn.Terminal.parent_completion/1` hands a
      parent for a child).
    * A name that resolves to no agent at all (no live process and no
      persisted row) is an error — almost certainly a typo — rather
      than silently counting as idle.

  ## A read-only wait

  `agents-wait` never starts an agent. Statuses come from
  `Nest.Agents.list_agents_info_for_space/1`, which merges live agents
  with their persisted rows and reports a persisted-only agent as `:idle`
  without starting it. This is deliberately *not* `Nest.Agents.get_info/2`:
  that on-demand-loads a persisted-only agent (`Supervisor.get_agent/2`
  starts it), so a wait that used it would start the very agent it is only
  observing, and would disagree with the empty-list path (which reads the
  listing). Both paths use the listing, so a given agent gets the same
  disposition however it is named.

  ## Bounded by elapsed time, never by a message count

  The target's own streaming traffic (`chat:delta`, `chat_message`,
  `shell:jobs`, ...) is broadcast on the same PubSub topic this process
  subscribes to, so bounding the wait by received messages would let a
  chatty target exhaust a long timeout in seconds (issue #20). The wait
  is bounded only by a `System.monotonic_time/1` deadline; each
  `receive ... after` slice is capped at the time remaining.

  Reaching the deadline is a normal result, not an error.
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Agents.Agent.WaitBudget
  alias Nest.Messages.MessageList
  alias Nest.Messages.ToolCall

  @doc """
  Run one `agents-wait` call. Returns `{:ok, content}` for the
  immediate, first-idle, and timeout results, and `{:error, content}`
  for an invalid argument or a named target that does not exist.
  """
  @spec run(map(), ToolCall.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(ctx, %ToolCall{} = tc) do
    with {:ok, names} <- extract_names(tc),
         {:ok, timeout} <- extract_timeout(tc) do
      case initial_statuses(ctx, names) do
        {:error, content} -> {:error, content}
        {:ok, []} -> {:ok, "No other agents in this space to wait for."}
        {:ok, statuses} -> wait_for_first_idle(ctx, statuses, timeout)
      end
    end
  end

  # -- target resolution --

  # An empty list means "every other non-archived agent in this space",
  # the same set `agents-list` reports. The caller is never a target — it
  # cannot observe its own idle while it is blocked here — and a
  # persisted-only agent has no process to wait on, so the listing's
  # `:idle` for it is already the right answer.
  defp initial_statuses(ctx, []) do
    statuses =
      ctx.space_id
      |> listing()
      |> Enum.reject(&(&1.name == ctx.agent_name))
      |> Enum.map(&{&1.name, &1.status})

    {:ok, statuses}
  end

  # Named targets resolve against the same listing, so a name that is not
  # in the space (no live process and no persisted row) is an error rather
  # than a silent idle.
  defp initial_statuses(ctx, names) do
    names = names |> Enum.uniq() |> List.delete(ctx.agent_name)
    listed = Map.new(listing(ctx.space_id), &{&1.name, &1.status})

    case Enum.find(names, &(not Map.has_key?(listed, &1))) do
      nil -> {:ok, Enum.map(names, &{&1, Map.fetch!(listed, &1)})}
      missing -> {:error, not_found_message(missing)}
    end
  end

  defp listing(space_id), do: Nest.Agents.list_agents_info_for_space(space_id)

  # -- the wait --

  defp wait_for_first_idle(ctx, statuses, timeout) do
    targets = Enum.map(statuses, &elem(&1, 0))
    deadline = System.monotonic_time(:millisecond) + timeout
    subscribe(ctx.space_id, targets)

    try do
      case busy_names(statuses) do
        [] -> {:ok, all_idle_message(targets)}
        busy -> await_idle(ctx, busy, deadline, timeout)
      end
    after
      unsubscribe(ctx.space_id, targets)
    end
  end

  # Subscribing happens after the initial status read, so a target that
  # goes idle in between misses its broadcast; the slice recheck in
  # `await_idle/4` catches that within one `WaitBudget.wait_slice_ms/0`.
  defp subscribe(space_id, names) do
    Enum.each(names, &Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.topic(space_id, &1)))
  end

  defp unsubscribe(space_id, names) do
    Enum.each(names, &Phoenix.PubSub.unsubscribe(Nest.PubSub, Broadcasts.topic(space_id, &1)))
  end

  defp busy_names(statuses) do
    for {name, status} <- statuses, status != :idle, do: name
  end

  defp await_idle(ctx, busy, deadline, timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("agents-wait: no target went idle within #{timeout}ms")
      {:ok, timeout_message(busy, timeout)}
    else
      receive do
        {:chat_status, %{status: "idle"}} ->
          check_idle(ctx, busy, deadline, timeout)

        # Every non-status message is discarded. The target's own
        # streaming traffic (`chat:delta`, `chat_message`, `shell:jobs`,
        # ...) lands on this topic too, and so can a late
        # `{:spawn_agent_result, ...}` from a sibling blocking
        # `agents-spawn` in the same batch that timed out first (the batch
        # runs sequentially in this worker, so that result is no longer
        # ours to deliver). None of them changes a target's status, so
        # none can end the wait.
        _other ->
          await_idle(ctx, busy, deadline, timeout)
      after
        min(WaitBudget.wait_slice_ms(), remaining) ->
          check_idle(ctx, busy, deadline, timeout)
      end
    end
  end

  # A status broadcast is only a *hint*: it can be the transient `:idle`
  # that issue #15's turn-end inbox drain publishes (`streaming → idle →
  # streaming`) before the target's queued work starts. Never decide on the
  # payload alone. The listing re-read is the authority, and the target's
  # status read is a synchronous call into the target (`Agent.get_public_info/1`,
  # the call `Nest.Agents.get_info/2` wraps), serialized behind the whole
  # settle — so it observes the final phase, not the transient one.
  # "Optimizing" this to trust the broadcast the way `PeerQuery` does would
  # inherit the same transient-idle bug (issue #31 removes the query path
  # that has it).
  defp check_idle(ctx, busy, deadline, timeout) do
    listed = Map.new(listing(ctx.space_id), &{&1.name, &1.status})

    case Enum.find_value(busy, &idle_target(listed, &1)) do
      nil -> await_idle(ctx, busy, deadline, timeout)
      {:idle, name} -> {:ok, idle_message(name, stop_message(ctx.space_id, name))}
      {:gone, name} -> {:ok, gone_message(name)}
    end
  end

  # A busy target "went idle" when its status is `:idle`, or when it is no
  # longer in the space at all (a vanished agent cannot be busy).
  defp idle_target(listed, name) do
    case Map.fetch(listed, name) do
      :error -> {:gone, name}
      {:ok, :idle} -> {:idle, name}
      {:ok, _busy} -> nil
    end
  end

  # -- reads --

  # The target's stop message: the text of its final assistant message,
  # or `""` when it ended its turn without one. Only a *live* target is
  # read: `Nest.Agents.get_messages/2` on-demand-loads a persisted-only
  # agent, and this wait must never start one.
  defp stop_message(space_id, name) do
    case Nest.Agents.Registry.lookup(space_id, name) do
      {:ok, _pid} -> read_stop_message(space_id, name)
      {:error, :not_found} -> ""
    end
  end

  defp read_stop_message(space_id, name) do
    case Nest.Agents.get_messages(space_id, name) do
      {:ok, messages} -> MessageList.last_assistant_text(messages)
      {:error, _reason} -> ""
    end
  end

  # -- args --

  # `names` must be a list of agent-name strings when present. A bare string
  # (a model that typos the type) or a list with a non-string element is
  # rejected rather than silently filtered, which would mean "every other
  # agent in the space" — a wait on unrelated agents. `nil` (omitted) and
  # `[]` both mean the same thing.
  defp extract_names(%ToolCall{arguments: args}) when is_map(args) do
    case Map.get(args, "names") do
      nil ->
        {:ok, []}

      names when is_list(names) ->
        if Enum.all?(names, &is_binary/1) do
          {:ok, names}
        else
          {:error, invalid_names_message(names)}
        end

      other ->
        {:error, invalid_names_message(other)}
    end
  end

  defp extract_names(_tc), do: {:ok, []}

  # A timeout must be a positive integer of milliseconds. A non-positive
  # one would produce "No agent went idle within -1ms" — reject it loudly.
  defp extract_timeout(%ToolCall{arguments: args}) when is_map(args) do
    case Map.get(args, "timeout") do
      nil -> {:ok, WaitBudget.default_wait_ms()}
      ms when is_integer(ms) and ms > 0 -> {:ok, ms}
      other -> {:error, invalid_timeout_message(other)}
    end
  end

  defp extract_timeout(_tc), do: {:ok, WaitBudget.default_wait_ms()}

  # -- messages --

  defp not_found_message(name), do: "Agent #{name} not found in this space."

  defp invalid_names_message(value) do
    "Invalid `names` argument: expected a list of agent names, got: #{inspect(value)}."
  end

  defp invalid_timeout_message(value) do
    "Invalid `timeout` argument: expected a positive integer of milliseconds, got: " <>
      inspect(value) <> "."
  end

  defp all_idle_message(targets) do
    "All agents are already idle: #{Enum.join(targets, ", ")}."
  end

  defp timeout_message(busy, timeout) do
    "No agent went idle within #{timeout}ms. Still busy: #{Enum.join(busy, ", ")}."
  end

  defp gone_message(name), do: "Agent #{name} is no longer running in this space."

  defp idle_message(name, "") do
    "Agent #{name} is idle, but its turn produced no text message."
  end

  defp idle_message(name, content) do
    "Agent #{name} is idle. Final message:\n#{content}"
  end
end
