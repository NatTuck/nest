defmodule Nest.Agents.Agent.WaitForIdle do
  @moduledoc """
  The wait-for-idle machinery shared by the `agents-wait-for-idle` tool's
  two modes (issues #62 and #54).

  Both modes wait on the same event — a named peer agent going idle — and
  share one loop, one status authority and one renderer so they cannot
  drift:

    * the **blocking** mode (`block: true`) runs `run/2` in the turn's tool
      worker and returns the partition inline, with **no payload** (issue
      #62: the payload is what made every report arrive twice);
    * the **async** mode (the default) registers interest and returns
      immediately; the `Nest.Agents.Agent.Watch` task runs `await/5` off the
      agent's turn, and the agent goes idle (issue #54) so a human can
      message it. When the event fires the caller gets a bare notice and can
      fetch the body with `agents-last-message`.

  ## A read-only wait

  Statuses come from `Nest.Agents.list_agents_info_for_space/1`, which merges
  live agents with their persisted rows and reports a persisted-only agent as
  `:idle` without starting it. This is deliberately *not* `Nest.Agents.get_info/2`:
  that on-demand-loads a persisted-only agent (`Supervisor.get_agent/2`
  starts it), so a wait that used it would start the very agent it is only
  observing, and would disagree with the empty-list path (which reads the
  listing). Both paths use the listing, so a given agent gets the same
  disposition however it is named.

  ## Woken by events, bounded by the caller's deadline

  The wait is woken by the events that can change a target's disposition,
  and by nothing else:

    * a target's `{:chat_status, %{status: "idle"}}` frame on its own
      topic — the status broadcast `Turn.run/6` emits whenever the derived
      status changes, so an idle transition is always announced;
    * a target's `:DOWN`. A target that is stopped or archived emits no
      frame at all (the topic is keyed by name and a process that is gone
      broadcasts nothing), so its monitor is the only event that reports it;
    * the caller's own deadline, which is reported as an ordinary timeout
      result.

  The ordering is established by construction, never guessed: the
  subscription (and the monitors) happen **before** the authoritative
  status read, so a change made before that read is already visible to it
  and a change made after it is delivered as an event. There is no window
  between the two in which a target could go idle unobserved, which is what
  a poll would be papering over — so there is no poll, and no
  `receive ... after` slice other than the time left on the deadline.

  Bounding the wait by received messages would be wrong for a different
  reason: the target's own streaming traffic (`chat:delta`, `chat_message`,
  `shell:jobs`, ...) is broadcast on the same PubSub topic this process
  subscribes to, so a chatty target could exhaust a long timeout in seconds
  (issue #20). The deadline is `System.monotonic_time/1`.

  Reaching the deadline is a normal result, not an error. The listing
  re-read is the authority, never the broadcast payload: a status broadcast
  can be the transient `:idle` that issue #15's turn-end inbox drain
  publishes (`streaming → idle → streaming`), so `partition/2` re-reads the
  listing (a synchronous call into the target, serialized behind the whole
  settle) rather than trusting the payload. "Optimizing" that to trust the
  broadcast would inherit the same transient-idle bug (#30).
  """

  require Logger

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Messages.ToolCall

  @default_wait_ms 300_000

  # The largest value `receive ... after` accepts. `:timeout` itself has no
  # upper limit, so a wait longer than this re-arms rather than reporting an
  # expiry it has not reached (see `loop/7`). Mirrors `ShellCmd`'s ceiling.
  @max_after_ms 4_294_967_295

  @type partition :: %{
          idle: [String.t()],
          still_busy: [String.t()],
          gone: [String.t()]
        }

  @doc """
  Run one **blocking** `agents-wait-for-idle` call. Returns `{:ok, content}`
  for the immediate, event, and timeout results, and `{:error, content}` for
  an invalid argument or a named target that does not exist.
  """
  @spec run(map(), ToolCall.t()) :: {:ok, String.t()} | {:error, String.t()}
  def run(ctx, %ToolCall{} = tc) do
    case resolve(ctx, tc) do
      {:error, content} ->
        {:error, content}

      {:ok, [], _timeout, _all?, _initial} ->
        {:ok, "No other agents in this space to wait for."}

      {:ok, names, timeout, all?, initial} ->
        case await(ctx.space_id, names, timeout, all?, initial) do
          {:ok, partition} -> {:ok, result_text(partition)}
          {:timeout, partition} -> timeout_result(partition, timeout)
        end
    end
  end

  @doc """
  Validate a call's arguments and resolve its target names against the space
  listing, returning the initial partition too. Shared by the blocking path
  (`run/2`) and the async registration (`Watch.register_call/2`) so both reject
  the same malformed input, agree on which names exist, and start from one
  status read.
  """
  @spec resolve(map(), ToolCall.t()) ::
          {:ok, [String.t()], pos_integer(), boolean(), partition()} | {:error, String.t()}
  def resolve(ctx, %ToolCall{} = tc) do
    with {:ok, names} <- extract_names(tc),
         {:ok, timeout} <- extract_timeout(tc),
         {:ok, all?} <- extract_all(tc),
         {:ok, initial} <- initial_partition(ctx, names) do
      {:ok, Enum.map(names_for(ctx, names, initial), & &1), timeout, all?, initial}
    end
  end

  # The names actually waited on: the named targets (minus the caller), or every
  # other agent in the space for the empty-list form.
  defp names_for(_ctx, [], initial), do: initial.idle ++ initial.still_busy
  defp names_for(ctx, names, _initial), do: names |> Enum.uniq() |> List.delete(ctx.agent_name)

  # The blocking timeout logs (the old `agents-wait` did); the async mode's
  # timeout is a normal notice, not a warning.
  defp timeout_result(partition, timeout) do
    Logger.warning("agents-wait-for-idle: no target changed within #{timeout}ms")
    {:ok, timeout_text(partition, timeout)}
  end

  @doc """
  Wait for the event and return the partition, or `{:timeout, partition}`.

  `all?` false (the default) fires as soon as any initially-busy target is
  idle (or gone); true waits until every target is idle (or gone). `monitor`
  is an optional caller monitor: a `:DOWN` aborts with `:caller_down` so an
  async watcher never outlives its agent.

  The subscription and the target monitors are installed **before** the
  authoritative status read, so a disposition change made after that read is
  delivered as an event and one made before it is already visible to it.
  There is no window between the two in which a target could go idle
  unobserved, which is what the poll this replaced was papering over.

  `initial` — the caller's own read, taken before the subscription — is the
  reference for what `any` waits for: a target that was busy when the call was
  made and is idle now is exactly the change `any` reports, however the two
  reads are spaced. The caller's own `timeout` is the only wall-clock value
  involved: it bounds the wait, and its expiry is the `{:timeout, partition}`
  result.
  """
  @spec await(integer(), [String.t()], pos_integer(), boolean(), partition(), reference() | nil) ::
          {:ok, partition()} | {:timeout, partition()} | :caller_down
  def await(space_id, names, timeout, all?, initial, monitor \\ nil) do
    subscribe(space_id, names)
    refs = monitor_targets(space_id, names)

    try do
      current = partition(space_id, names)
      initial_busy = MapSet.new(initial.still_busy)
      deadline = System.monotonic_time(:millisecond) + timeout

      if met?(current, initial_busy, all?) do
        {:ok, current}
      else
        loop(space_id, names, initial_busy, deadline, timeout, all?, monitor)
      end
    after
      Enum.each(refs, &Process.demonitor(&1, [:flush]))
      unsubscribe(space_id, names)
    end
  end

  # Monitor every target that has a live process, and return the refs so the
  # wait can drop them on the way out. A target that is stopped or archived
  # emits no frame at all (see the moduledoc), so its `:DOWN` is the event that
  # reports it; the loop treats it exactly as it treats a status frame — as
  # "re-read the authority".
  #
  # A persisted-only target has no process to monitor and the listing reports
  # it `:idle`, so there is nothing to watch for — and nothing to start: the
  # wait never brings an agent up (see "A read-only wait" above).
  defp monitor_targets(space_id, names) do
    Enum.flat_map(names, fn name ->
      case Nest.Agents.Registry.lookup(space_id, name) do
        {:ok, pid} -> [Process.monitor(pid)]
        {:error, :not_found} -> []
      end
    end)
  end

  # The event is "the busy set shrank" for `any` and "the busy set is empty"
  # for `all`. Tracking the *initial* busy set is what keeps `any` from firing
  # on a target that was already idle before the call; an initially-empty busy
  # set means there is nothing to wait for.
  defp met?(partition, initial_busy, all?) do
    busy = MapSet.new(partition.still_busy)

    if all? do
      MapSet.size(busy) == 0
    else
      MapSet.size(initial_busy) == 0 or Enum.any?(initial_busy, &(&1 not in busy))
    end
  end

  # The event loop. Every wake-up is either a real event or the caller's
  # deadline: the `after` value is the time left on the deadline, so a wake-up
  # that is not an event *is* the expiry. There is no poll slice.
  defp loop(space_id, names, initial_busy, deadline, timeout, all?, monitor) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:timeout, partition(space_id, names)}
    else
      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} ->
          :caller_down

        # A target died: a stopped or archived agent broadcasts nothing, so its
        # monitor is the event that says "re-read". Any other `:DOWN` in this
        # mailbox (a stale one, or one this process took for another reason)
        # costs nothing but the read.
        {:DOWN, _ref, :process, _pid, _reason} ->
          recheck(space_id, names, initial_busy, deadline, timeout, all?, monitor)

        {:chat_status, %{status: "idle"}} ->
          recheck(space_id, names, initial_busy, deadline, timeout, all?, monitor)

        # Every non-status message is discarded. The target's own streaming
        # traffic lands on this topic too, and so can a late delivery meant
        # for a sibling call. None of them changes a target's status.
        _other ->
          loop(space_id, names, initial_busy, deadline, timeout, all?, monitor)
      after
        min(remaining, @max_after_ms) ->
          # `remaining` is positive here, so this is either the caller's
          # deadline or the `receive` ceiling: a wait longer than `after`
          # accepts re-arms rather than reporting an expiry it has not reached.
          if remaining > @max_after_ms do
            loop(space_id, names, initial_busy, deadline, timeout, all?, monitor)
          else
            {:timeout, partition(space_id, names)}
          end
      end
    end
  end

  defp recheck(space_id, names, initial_busy, deadline, timeout, all?, monitor) do
    partition = partition(space_id, names)

    if met?(partition, initial_busy, all?) do
      {:ok, partition}
    else
      loop(space_id, names, initial_busy, deadline, timeout, all?, monitor)
    end
  end

  @doc """
  Re-read the space listing and partition `names` into idle, still-busy and
  gone. A name no longer in the listing is `gone` — a vanished agent cannot be
  busy — which is the disposition the old wait reported as a normal result.
  """
  @spec partition(integer(), [String.t()]) :: partition()
  def partition(space_id, names) do
    listed = Map.new(listing(space_id), &{&1.name, &1.status})
    {idle, busy, gone} = Enum.reduce(names, {[], [], []}, &classify(&2, &1, listed))

    %{idle: Enum.reverse(idle), still_busy: Enum.reverse(busy), gone: Enum.reverse(gone)}
  end

  defp classify({idle, busy, gone}, name, listed) do
    case Map.fetch(listed, name) do
      :error -> {idle, busy, [name | gone]}
      {:ok, :idle} -> {[name | idle], busy, gone}
      {:ok, _busy} -> {idle, [name | busy], gone}
    end
  end

  # -- target resolution --

  # An empty list means "every other non-archived agent in this space",
  # the same set `agents-list` reports. The caller is never a target — it
  # cannot observe its own idle — and a persisted-only agent has no process to
  # wait on, so the listing's `:idle` for it is already the right answer.
  @doc false
  @spec initial_partition(map(), [String.t()]) :: {:ok, partition()} | {:error, String.t()}
  def initial_partition(ctx, []) do
    statuses =
      ctx.space_id
      |> listing()
      |> Enum.reject(&(&1.name == ctx.agent_name))
      |> Enum.map(&{&1.name, &1.status})

    {:ok, statuses_to_partition(statuses)}
  end

  # Named targets resolve against the same listing, so a name that is not
  # in the space (no live process and no persisted row) is an error rather
  # than a silent idle.
  def initial_partition(ctx, names) do
    names = names |> Enum.uniq() |> List.delete(ctx.agent_name)
    listed = Map.new(listing(ctx.space_id), &{&1.name, &1.status})

    case Enum.find(names, &(not Map.has_key?(listed, &1))) do
      nil -> {:ok, statuses_to_partition(Enum.map(names, &{&1, Map.fetch!(listed, &1)}))}
      missing -> {:error, not_found_message(missing)}
    end
  end

  defp statuses_to_partition(statuses) do
    {idle, busy} = Enum.split_with(statuses, fn {_name, status} -> status == :idle end)

    %{
      idle: Enum.map(idle, &elem(&1, 0)),
      still_busy: Enum.map(busy, &elem(&1, 0)),
      gone: []
    }
  end

  defp listing(space_id), do: Nest.Agents.list_agents_info_for_space(space_id)

  defp subscribe(space_id, names) do
    Enum.each(names, &Phoenix.PubSub.subscribe(Nest.PubSub, Broadcasts.topic(space_id, &1)))
  end

  defp unsubscribe(space_id, names) do
    Enum.each(names, &Phoenix.PubSub.unsubscribe(Nest.PubSub, Broadcasts.topic(space_id, &1)))
  end

  # -- rendering --

  @doc """
  The blocking result: the partition, with no payload (issue #62).
  """
  @spec result_text(partition()) :: String.t()
  def result_text(partition) do
    "Idle: #{names_or_none(partition.idle)}. " <>
      "Still busy: #{names_or_none(partition.still_busy)}." <> gone_suffix(partition.gone)
  end

  @doc "The blocking timeout result, distinguishable from a success."
  @spec timeout_text(partition(), pos_integer()) :: String.t()
  def timeout_text(partition, timeout) do
    "Timed out after #{timeout}ms. " <>
      "Idle: #{names_or_none(partition.idle)}. " <>
      "Still busy: #{names_or_none(partition.still_busy)}." <> gone_suffix(partition.gone)
  end

  @doc """
  The async confirmation the caller reads when interest is registered. It
  names what is already idle and what is being watched, and says nothing
  about the body (that arrives later, as a notice or a delivery).
  """
  @spec watch_confirmation(partition()) :: String.t()
  def watch_confirmation(partition) do
    if partition.still_busy == [] do
      "All agents are already idle: #{names_or_none(partition.idle)}." <>
        gone_suffix(partition.gone)
    else
      "Watching (you will be notified): #{names_or_none(partition.still_busy)}. " <>
        "Already idle: #{names_or_none(partition.idle)}." <> gone_suffix(partition.gone)
    end
  end

  @doc """
  The bare notice a fired async watch delivers (issue #54). No payload: the
  body comes from the delivery or `agents-last-message`.
  """
  @spec notice_text(partition()) :: String.t()
  def notice_text(partition) do
    "Agents now idle: #{names_or_none(partition.idle)}. " <>
      "Still busy: #{names_or_none(partition.still_busy)}." <> gone_suffix(partition.gone)
  end

  @doc "The bare notice an expired async watch delivers."
  @spec timeout_notice_text(partition(), pos_integer()) :: String.t()
  def timeout_notice_text(partition, timeout) do
    "Timed out after #{timeout}ms waiting for agents to go idle. " <>
      "Idle: #{names_or_none(partition.idle)}. " <>
      "Still busy: #{names_or_none(partition.still_busy)}." <> gone_suffix(partition.gone)
  end

  defp names_or_none([]), do: "(none)"
  defp names_or_none(names), do: Enum.join(names, ", ")

  defp gone_suffix([]), do: ""
  defp gone_suffix(gone), do: " No longer running: #{Enum.join(gone, ", ")}."

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
      nil -> {:ok, default_wait_ms()}
      ms when is_integer(ms) and ms > 0 -> {:ok, ms}
      other -> {:error, invalid_timeout_message(other)}
    end
  end

  defp extract_timeout(_tc), do: {:ok, default_wait_ms()}

  # `all` is a boolean when present; anything else is a model typo.
  defp extract_all(%ToolCall{arguments: args}) when is_map(args) do
    case Map.get(args, "all") do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, "Invalid `all` argument: expected a boolean, got: #{inspect(other)}."}
    end
  end

  defp extract_all(_tc), do: {:ok, false}

  # -- messages --

  defp not_found_message(name), do: "Agent #{name} not found in this space."

  defp invalid_names_message(value) do
    "Invalid `names` argument: expected a list of agent names, got: #{inspect(value)}."
  end

  defp invalid_timeout_message(value) do
    "Invalid `timeout` argument: expected a positive integer of milliseconds, got: " <>
      inspect(value) <> "."
  end

  # The default wall-clock wait, in milliseconds.
  @spec default_wait_ms() :: pos_integer()
  def default_wait_ms, do: @default_wait_ms
end
