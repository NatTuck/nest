defmodule Nest.Agents.Agent.WaitForIdle do
  @moduledoc """
  The wait-for-idle machinery behind the `agents-wait` tool (issues #62 and
  #54).

  A wait is one event — a named peer agent going idle — observed by one loop,
  one status authority and one renderer, so the parts cannot drift:

    * the tool worker registers interest and returns immediately, reporting
      that a watch is outstanding (`Nest.Agents.Agent.Watch`); the machine
      reads that off the result and ends the caller's turn, so the agent goes
      idle (issue #54) and a human can message it;
    * the watch's task runs `await/6` off the agent's turn. When the event
      fires the caller is woken with a bare notice — no payload (issue #62:
      the payload is what made every report arrive twice) — and can fetch the
      body with `agents-last-message`.

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
      status changes. *Every* status change wakes the wait, not only the
      idle one: a target that goes busy after the read is a target worth
      watching, and its own busy frame is the only notice that it is;
    * a target's `:DOWN`. A target that is stopped or archived emits no
      frame at all (the topic is keyed by name and a process that is gone
      broadcasts nothing), so its monitor is the only event that reports it;
    * the caller's own deadline, which is reported as an ordinary timeout
      result.

  The ordering is established by construction, never guessed: the
  subscription happens **before** the authoritative status read, so a
  change made before that read is already visible to it and a change made
  after it is delivered as an event. There is no window between the two in
  which a target could go idle unobserved, which is what a poll would be
  papering over — so there is no poll, and no `receive ... after` slice
  other than the time left on the deadline.

  The monitors are the same argument for the event that has no frame. Every
  target the read reports **busy** is monitored, and every re-read
  re-installs the monitors, so a process that takes a target's name after
  the first read is watched too (the map is keyed by pid for exactly that
  reason; a `{:via, Registry, …}` tuple would resolve the name once, at
  monitor time). A target that is *idle* needs no monitor: its death cannot
  change any decision — `partition/2` reports a name with no live process
  as `:idle` or `gone`, both of which are "not busy" — and the disposition
  text comes from the read taken when the wait fires, so it is honest
  either way.

  ## The immediate decision is the authoritative read's

  A wait that is already satisfied at the authoritative read returns at
  once, and *that* read decides it. So a target that the caller's own read
  saw idle but which is busy by then blocks the wait (`all: true`
  especially: returning `Idle: …` for a target that is running is a lie),
  and the partition a caller is handed is the fresh one, never the read the
  caller took before the subscription.

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

  alias Nest.Agents.Agent.Broadcasts
  alias Nest.Messages.ToolCall

  @default_wait_ms 300_000

  # The largest value `receive ... after` accepts. `:timeout` itself has no
  # upper limit, so a wait longer than this re-arms rather than reporting an
  # expiry it has not reached (see `loop/8`). Mirrors `ShellCmd`'s ceiling.
  @max_after_ms 4_294_967_295

  @type partition :: %{
          idle: [String.t()],
          still_busy: [String.t()],
          gone: [String.t()]
        }

  @doc """
  Validate a call's arguments and resolve its target names against the space
  listing, returning the initial partition too. `Watch.register_call/2` is the
  only caller: it is what rejects a malformed argument, decides which names
  exist, and takes the one status read the registration starts from.
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

  @doc """
  Wait for the event and return the partition, or `{:timeout, partition}`.

  `all?` false (the default) fires as soon as any initially-busy target is
  idle (or gone); true waits until every target is idle (or gone). `monitor`
  is an optional caller monitor: a `:DOWN` aborts with `:caller_down` so an
  async watcher never outlives its agent.

  The subscription is installed **before** the authoritative status read, so a
  disposition change made after that read is delivered as an event and one
  made before it is already visible to it; the targets the read finds busy are
  monitored, and every re-read re-installs those monitors, so a process that
  takes a target's name later is watched too. See the moduledoc.

  `initial` — the caller's own read, taken before the subscription — is the
  reference for what `any` waits for: a target that was busy when the call was
  made and is idle now is exactly the change `any` reports, however the two
  reads are spaced. Everything else (the immediate decision, and the partition
  the caller is handed) comes from the authoritative read.

  The caller's own `timeout` is the only wall-clock value involved: it bounds
  the wait, and its expiry is the `{:timeout, partition}` result.
  """
  @spec await(integer(), [String.t()], pos_integer(), boolean(), partition(), reference() | nil) ::
          {:ok, partition()} | {:timeout, partition()} | :caller_down
  def await(space_id, names, timeout, all?, initial, monitor \\ nil) do
    subscribe(space_id, names)

    initial_busy = MapSet.new(initial.still_busy)
    deadline = System.monotonic_time(:millisecond) + timeout

    # The first read is a `check/8` like any other — it is the authoritative
    # read, it installs the monitors for whatever it finds busy, and it takes
    # the immediate decision.
    {result, monitors} =
      check(space_id, names, initial_busy, deadline, timeout, all?, monitor, %{})

    # Dropped here rather than in the `after`: a `try`'s `after` cannot see a
    # value bound in its body, and the monitor set grows as the wait re-reads.
    # The `after` owns the subscription, which is keyed by name and so needs no
    # state to undo. Nothing in this body raises, so there is no path that
    # reaches the `after` with monitors still installed.
    demonitor_all(monitors)
    result
  after
    unsubscribe(space_id, names)
  end

  # Monitor every target that has a live process, keyed by pid so a target whose
  # process is replaced is monitored again rather than mistaken for one we
  # already hold.
  #
  # Every target, not only the ones the last read called busy, and run **before**
  # the read that decides (see `check/8`). A name can be busy while the process
  # answering for it is not one we hold: the listing reads each name's status
  # from a live process, so a name it calls busy had a live process *at that
  # read*, and the process it had may be a replacement for the one we monitored.
  # Monitoring first means the process the read is about is already watched
  # whenever the read can see it, and a replacement cannot slip between the two
  # — its predecessor's death would have delivered a `:DOWN` and its own start
  # a status frame, so either way this runs again.
  #
  # A persisted-only target has no process to monitor and the listing reports it
  # `:idle`, so there is nothing to watch for — and nothing to start: the wait
  # never brings an agent up (see "A read-only wait" above).
  defp monitor_targets(space_id, names, monitors) do
    Enum.reduce(names, monitors, &monitor_one(space_id, &1, &2))
  end

  defp monitor_one(space_id, name, monitors) do
    case Nest.Agents.Registry.lookup(space_id, name) do
      {:ok, pid} -> Map.put_new_lazy(monitors, pid, fn -> Process.monitor(pid) end)
      {:error, :not_found} -> monitors
    end
  end

  defp demonitor_all(monitors) do
    Enum.each(monitors, fn {_pid, ref} -> Process.demonitor(ref, [:flush]) end)
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
  #
  # It returns `{result, monitors}`: the monitor set grows as targets are
  # re-read, so the caller owns dropping it.
  defp loop(space_id, names, initial_busy, deadline, timeout, all?, monitor, monitors) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {{:timeout, partition(space_id, names)}, monitors}
    else
      # Deliberately *no* catch-all: this is a selective receive. The target's
      # own streaming traffic (`chat:delta`, `chat_message`, `shell:jobs`, …)
      # lands on the same topic and so can a late delivery meant for a sibling
      # call — but none of it can change a target's disposition, so the
      # runtime skips it and leaves it in the mailbox. A `_other` clause here
      # would be a drain loop: it would take every non-matching message out of
      # the mailbox and re-`receive` just to discard it.
      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} ->
          {:caller_down, monitors}

        # A target died, or changed status; both mean the same thing here —
        # re-read the authority (and re-install monitors for whatever is busy
        # now). A target that is stopped or archived broadcasts nothing, so its
        # monitor is the only event that reports it. Every other `:DOWN` in this
        # mailbox (a stale one, or one this process took for another reason)
        # costs nothing but the read.
        {:DOWN, _ref, :process, _pid, _reason} ->
          check(space_id, names, initial_busy, deadline, timeout, all?, monitor, monitors)

        {:chat_status, _payload} ->
          check(space_id, names, initial_busy, deadline, timeout, all?, monitor, monitors)
      after
        min(remaining, @max_after_ms) ->
          # `remaining` is positive here, so this is either the caller's
          # deadline or the `receive` ceiling: a wait longer than `after`
          # accepts re-arms rather than reporting an expiry it has not reached.
          if remaining > @max_after_ms do
            loop(space_id, names, initial_busy, deadline, timeout, all?, monitor, monitors)
          else
            {{:timeout, partition(space_id, names)}, monitors}
          end
      end
    end
  end

  # The authoritative read and the decision it drives, in one place so the first
  # read and every event-driven re-read cannot drift. The monitors go on first,
  # so the read cannot see a process nothing is watching (see `monitor_targets/3`).
  # Returns `{result, monitors}`: the monitor set grows here, so the caller owns
  # dropping it.
  defp check(space_id, names, initial_busy, deadline, timeout, all?, monitor, monitors) do
    monitors = monitor_targets(space_id, names, monitors)
    current = partition(space_id, names)

    if met?(current, initial_busy, all?) do
      {{:ok, current}, monitors}
    else
      loop(space_id, names, initial_busy, deadline, timeout, all?, monitor, monitors)
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
  The confirmation the caller reads when interest is registered. It names what
  is already idle and what is being watched, and says nothing about the body
  (that arrives later, as a notice or a delivery).
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
  The bare notice a fired watch delivers (issue #54). No payload: the body
  comes from the delivery or `agents-last-message`.
  """
  @spec notice_text(partition()) :: String.t()
  def notice_text(partition) do
    "Agents now idle: #{names_or_none(partition.idle)}. " <>
      "Still busy: #{names_or_none(partition.still_busy)}." <> gone_suffix(partition.gone)
  end

  @doc "The bare notice an expired watch delivers."
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
