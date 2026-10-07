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
  alias Nest.Messages.MessageList
  alias Nest.Messages.ToolCall

  # Mirrors `PeerQuery`'s `@wait_slice_ms` and `ToolLoop`'s
  # `@default_wait_ms`: they bound the same kind of blocking sub-agent
  # wait.
  @default_wait_ms 300_000
  @wait_slice_ms 250

  @doc """
  Run one `agents-wait` call. Returns `{:ok, content}` for the
  immediate, first-idle, and timeout results, and `{:error, content}`
  only when a named target does not exist.
  """
  @spec run(map(), ToolCall.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(ctx, %ToolCall{} = tc) do
    case initial_statuses(ctx, extract_names(tc)) do
      {:error, content} -> {:error, content}
      {:ok, []} -> {:ok, "No other agents in this space to wait for."}
      {:ok, statuses} -> wait_for_first_idle(ctx, statuses, extract_timeout(tc))
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
      |> Nest.Agents.list_agents_info_for_space()
      |> Enum.reject(&(&1.name == ctx.agent_name))
      |> Enum.map(&{&1.name, &1.status})

    {:ok, statuses}
  end

  defp initial_statuses(ctx, names) do
    names = names |> Enum.uniq() |> List.delete(ctx.agent_name)
    read_statuses(ctx.space_id, names)
  end

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
  # goes idle in between misses its broadcast; the `@wait_slice_ms`
  # recheck in `await_idle/4` catches that within one slice.
  defp subscribe(space_id, names) do
    Enum.each(names, &Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.topic(space_id, &1)))
  end

  defp unsubscribe(space_id, names) do
    Enum.each(names, &Phoenix.PubSub.unsubscribe(Nest.PubSub, Broadcasts.topic(space_id, &1)))
  end

  defp busy_names(statuses) do
    for {name, status} <- statuses, status != :idle, do: name
  end

  # One status read per target. A name that resolves to nothing is
  # reported as an error rather than treated as idle.
  defp read_statuses(space_id, names) do
    names
    |> Enum.reduce_while([], fn name, acc ->
      case status(space_id, name) do
        {:ok, status} -> {:cont, [{name, status} | acc]}
        {:error, :not_found} -> {:halt, {:error, not_found_message(name)}}
      end
    end)
    |> case do
      {:error, content} -> {:error, content}
      pairs -> {:ok, Enum.reverse(pairs)}
    end
  end

  defp await_idle(ctx, busy, deadline, timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("agents-wait: no target went idle within #{timeout}ms")
      {:ok, timeout_message(busy, timeout)}
    else
      receive do
        {:chat_status, %{status: "idle"}} -> check_idle(ctx, busy, deadline, timeout)
        _other -> await_idle(ctx, busy, deadline, timeout)
      after
        min(@wait_slice_ms, remaining) -> check_idle(ctx, busy, deadline, timeout)
      end
    end
  end

  defp check_idle(ctx, busy, deadline, timeout) do
    case Enum.find_value(busy, &idle_target(ctx.space_id, &1)) do
      nil -> await_idle(ctx, busy, deadline, timeout)
      {:idle, name} -> {:ok, idle_message(name, stop_message(ctx.space_id, name))}
      {:gone, name} -> {:ok, gone_message(name)}
    end
  end

  # A busy target "went idle" when its status is `:idle`, or when it is
  # no longer present at all (a vanished agent cannot be busy).
  defp idle_target(space_id, name) do
    case status(space_id, name) do
      {:ok, :idle} -> {:idle, name}
      {:error, :not_found} -> {:gone, name}
      {:ok, _busy} -> nil
    end
  end

  # -- reads --

  defp status(space_id, name) do
    case Nest.Agents.get_info(space_id, name) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # The target's stop message: the text of its final assistant message,
  # or `""` when it ended its turn without one.
  defp stop_message(space_id, name) do
    case Nest.Agents.get_messages(space_id, name) do
      {:ok, messages} -> MessageList.last_assistant_text(messages)
      {:error, _reason} -> ""
    end
  end

  # -- args --

  defp extract_names(%ToolCall{arguments: args}) when is_map(args) do
    case Map.get(args, "names") do
      names when is_list(names) -> Enum.filter(names, &is_binary/1)
      _ -> []
    end
  end

  defp extract_names(_tc), do: []

  defp extract_timeout(%ToolCall{arguments: args}) when is_map(args) do
    case Map.get(args, "timeout") do
      ms when is_integer(ms) -> ms
      _ -> @default_wait_ms
    end
  end

  defp extract_timeout(_tc), do: @default_wait_ms

  # -- messages --

  defp not_found_message(name), do: "Agent #{name} not found in this space."

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
