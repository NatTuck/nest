defmodule Nest.Agents.SpaceGate do
  @moduledoc """
  The per-space **before-starts latch**.

  A space's environment — its workspace, its network access and its sandbox
  backend — is carried on every agent's `Nest.Sandbox.Mounts`, which is what its
  caps resolve from and what its tool closures were built with. So an edit to the
  space has to *reach* the agents (`Nest.Spaces.update_environment/2`), and until
  it does, no tool may start: a command that began in the old environment and
  finished in the new one, or a container torn down under a running command, is
  exactly the kind of half-changed state the edit exists to avoid.

  This module is the latch that makes the window safe. While a space is held:

    * every tool use waits at the gate before it starts
      (`Nest.Agents.Agent.BatchSizer`'s per-call dispatch), and then runs with
      the mounts its **batch** was built with: a batch that starts after the
      write reads the new row and runs under the new values, while a batch
      already in flight is a snapshot taken before it and keeps the old ones —
      that batch is cancelled where it has a long call running
      (`Nest.Agents.Agent.cancel_tools/2`) and the agent is told, but the calls
      it has left still run against the mounts it was built with;
    * an agent that is starting waits at the gate too, so a process cannot read
      the row halfway through the write;
    * nothing is refused. A blocked start or tool call is a *pause*, so cancelling
      an edit costs nothing: the latch is released and everything proceeds.

  What the latch is **not** is a mutex. It does not drain: work that was already
  running when it went up is not waited for. The edit cancels that work itself
  (`Nest.Agents.Agent.cancel_tools/2`), which is what lets the latch be momentary
  on the reader side — one `:ets.member/2` on the hot path — while a tool batch
  that is already executing is handled by the cancellation rather than by a
  count.

  ## What can be cancelled, and why that is a rule about *time*

  Only tools that **take time** can be cancelled, because only they own an OS
  process to stop. The cancellation is a message to the turn's worker pids
  (`Nest.Agents.Agent.Turn.cancel_tools/2`), and the one clause that matches it is
  `Nest.Tools.ShellCmd.collect_output/5`'s: it stops the process and returns a
  tool error, so the agent can re-issue the call.

  Every other tool is *short* — `file-write`, `agents-spawn`, `context-compact`,
  anything that answers from memory — and needs no cancellation. A short tool that
  arrives while the latch is up simply waits at the gate and then runs against the
  new values, so nothing is burned and nothing is retried. That is a statement
  about duration, not a list of exempted tools: a future tool that spawns an OS
  process or otherwise runs unbounded time belongs in the cancellable set (it
  needs a `{:cancel_tool, …}` clause that stops it); a future tool that merely
  waits for the latch does not, and giving it a clause would report a cancellation
  it never had.

  ## Why it cannot outlive its owner

  A hold is owned by the process that asked for it (a lobby channel). It is
  announced (`{:space_locked, space_id}`) when it goes up, so every session that
  can see the space shows the pause — not only the one that is editing it — and
  it is released in three ways, all of which broadcast
  `{:space_unlocked, space_id}`:

    * `release/1` by the owner;
    * the owner's `:DOWN` — a closed tab, a crashed channel;
    * a TTL, for a client that is alive but never answers its own dialog.

  So a wait can be unbounded and still terminate, which is what makes
  `await/1`'s `receive` safe: the latch always comes down.

  ## Where the state lives

  The claims are in a `:protected` ETS table owned by this process: reads are
  lock-free from any process, and the hot path (`held?/1`, once per tool use)
  never calls the server. Writes are rare and go through it, because a write also
  has to arm the monitor and the timer.

  The wake-up rides its own PubSub topic rather than `Broadcasts.space_topic/1`,
  which carries the agent and space frames: a `{:space_unlocked, _}` frame there
  would reach `NestWeb.LobbyChannel`'s unknown-frame clause and log for every
  watcher. The gate's topic is subscribed by the agents of the space (a deferred
  turn waits for it) and by the lobby channels that show the paused banner, and by
  nobody else.
  """

  use GenServer

  require Logger

  @table :nest_space_gate

  # How long a claim may outlive its owner's last word. Long enough for a human to
  # read the confirmation dialog and decide; short enough that an abandoned one
  # does not pause a space indefinitely. A test that needs the expiry sooner
  # passes its own to `hold/3`; there is deliberately **no** application setting,
  # because one would shorten every space's claim at once — which is what made two
  # suite tests flake while passing alone.
  @ttl_ms 120_000

  # The ceiling on a wait. It is a bound on how long a waiter blocks, not proof
  # that the claim was lost: a space re-held across its own TTLs outlasts it (two
  # consecutive claims are longer than this), and so does a space held again
  # immediately after a release. Reaching it therefore means "this waiter has
  # waited long enough" — it proceeds rather than hanging a tool worker, and the
  # log says that much without diagnosing a cause it cannot know.
  @await_ms @ttl_ms + 60_000

  @type reason :: :space_edit

  # --- client ---

  @doc "The PubSub topic a held space's waiters wake on."
  @spec topic(integer()) :: String.t()
  def topic(space_id) when is_integer(space_id), do: "space_gate:#{space_id}"

  @doc """
  Whether `space_id` is held. One ETS read; safe to call on any process.
  """
  @spec held?(integer()) :: boolean()
  def held?(space_id) when is_integer(space_id) do
    :ets.member(@table, space_id)
  rescue
    # The table is the gate process's, so it goes when that process does: a
    # restart between this call and the read leaves no latch to read, which is
    # the same answer as "not held" (`await/2` and `chat_or_queue/5` both treat
    # it as a pause that is over). Catching it here rather than probing with
    # `:ets.whereis/1` keeps the hot path one call and closes the window between
    # the probe and the read.
    ArgumentError -> false
  end

  @doc """
  Hold `space_id` on behalf of the calling process.

  Idempotent for the caller that already holds it, so a two-push edit (a preview
  and then a confirmation) keeps one claim across both — and **re-arms** its TTL,
  so the claim covers the confirmation's own quiesce and write rather than
  expiring in the middle of them. A *different* caller is refused: two sessions
  editing one space at once is what the latch is for.

  The `ttl_ms` argument exists for tests, which need a claim to expire without
  waiting two minutes. It is per-hold rather than an application setting on
  purpose: a global knob would be changed by one test and silently shorten every
  other test's claim (and every other space's, in production, if it were ever
  set there).
  """
  @spec hold(integer(), reason(), pos_integer() | nil) :: :ok | {:error, :already_held}
  def hold(space_id, reason \\ :space_edit, ttl_ms \\ nil) when is_integer(space_id) do
    GenServer.call(__MODULE__, {:hold, space_id, reason, self(), ttl_ms})
  end

  @doc """
  Release `space_id`, if the calling process is the one holding it.

  A release from anyone else is a no-op: a channel must not be able to unpause a
  space another session is editing.
  """
  @spec release(integer()) :: :ok
  def release(space_id) when is_integer(space_id) do
    GenServer.call(__MODULE__, {:release, space_id, self()})
  end

  @doc """
  Wait until `space_id` is not held, then return `:ok`.

  The unheld path is one ETS read. The held path subscribes **before** its second
  read — the ordering `Nest.Agents.Agent.WaitForIdle` documents — so a release
  that lands between the two cannot be missed and no poll is needed.
  """
  @spec await(integer(), non_neg_integer()) :: :ok
  def await(space_id, timeout \\ @await_ms)

  def await(space_id, timeout) when is_integer(space_id) do
    if held?(space_id) do
      topic = topic(space_id)
      Phoenix.PubSub.subscribe(Nest.PubSub, topic)

      try do
        if held?(space_id), do: wait_until_open(space_id, timeout), else: :ok
      after
        Phoenix.PubSub.unsubscribe(Nest.PubSub, topic)
      end
    else
      :ok
    end
  end

  # A tool-loop context with no space behind it (the `BatchSizer` unit tests build
  # one) has no environment for the latch to protect, and no space id could be
  # held in the first place — the table is keyed by integer.
  def await(_space_id, _timeout), do: :ok

  defp wait_until_open(space_id, timeout) do
    receive do
      {:space_unlocked, ^space_id} ->
        # Re-held before this process ran: wait for the next release. A latch is
        # a pause, not a one-shot event.
        if held?(space_id), do: wait_until_open(space_id, timeout), else: :ok
    after
      timeout ->
        Logger.warning(
          "space #{space_id} stayed held past the wait ceiling (#{timeout}ms); " <>
            "proceeding without the latch"
        )

        :ok
    end
  end

  # --- server ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    table =
      :ets.new(@table, [
        :named_table,
        :protected,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{claims: %{}, table: table}}
  end

  @impl true
  def handle_call({:hold, space_id, reason, owner, ttl_ms}, _from, state) do
    case Map.fetch(state.claims, space_id) do
      :error ->
        {:reply, :ok, claim(state, space_id, reason, owner, ttl_ms)}

      {:ok, %{owner: ^owner} = claim} ->
        # The same caller asking again: the preview, and then the confirmation, of
        # one edit. The TTL is **re-armed** rather than left running from the
        # first hold, because the two asks mean different things: a preview
        # abandoned without an answer sends nothing, so nothing renews it and the
        # claim still expires (the dialog's own close releases it sooner), while a
        # confirmation owns the latch for its own duration — a user who reads the
        # plan for two minutes and then clicks "Stop and save" must not have the
        # latch drop in the middle of the quiesce and the write.
        {:reply, :ok, renew(state, space_id, claim, ttl_ms)}

      {:ok, _other} ->
        {:reply, {:error, :already_held}, state}
    end
  end

  def handle_call({:release, space_id, owner}, _from, state) do
    case Map.fetch(state.claims, space_id) do
      {:ok, %{owner: ^owner}} -> {:reply, :ok, drop(state, space_id)}
      {:ok, _other} -> {:reply, :ok, state}
      :error -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, drop_where(state, &(&1.ref == ref))}
  end

  def handle_info({:ttl, space_id, token}, state) do
    case Map.fetch(state.claims, space_id) do
      {:ok, %{token: ^token} = claim} ->
        # A claim that reaches its TTL is a client that went silent mid-edit (a
        # closed laptop, a killed tab whose channel outlived it): the space
        # resumes *without* the edit, and this is the only record of why it did.
        # A warning rather than an info, because an abandoned edit is the
        # noteworthy case — the operator wants to see it, and the reason names
        # what was being done.
        Logger.warning(
          "space #{space_id}: the #{claim.reason} claim expired after " <>
            "#{claim.ttl_ms}ms; the space resumed without it"
        )

        {:noreply, drop(state, space_id)}

      # A timer this claim has already replaced (it was re-armed): the claim it
      # belonged to is gone, and dropping this one would end the renewed claim.
      _other ->
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.warning("#{inspect(__MODULE__)} ignoring unknown message: #{inspect(message)}")
    {:noreply, state}
  end

  defp claim(state, space_id, reason, owner, ttl_ms) do
    ttl_ms = ttl_ms || @ttl_ms
    {timer, token} = arm_ttl(space_id, ttl_ms)
    ref = Process.monitor(owner)
    claim = %{owner: owner, ref: ref, timer: timer, token: token, reason: reason, ttl_ms: ttl_ms}

    :ets.insert(@table, {space_id, reason})
    Phoenix.PubSub.broadcast(Nest.PubSub, topic(space_id), {:space_locked, space_id})

    %{state | claims: Map.put(state.claims, space_id, claim)}
  end

  # Re-arm a claim's TTL without disturbing its owner or its monitor.
  #
  # Each arm gets a **fresh token**, which is what makes the old timer harmless:
  # `Process.cancel_timer/1` returns `false` for a timer that has already fired,
  # and that message is then already in this mailbox — carrying the *old* token, so
  # it matches no claim and is ignored, rather than dropping the one we just
  # renewed. (Keying the message on the monitor ref, as this did first, cannot tell
  # the two apart.)
  defp renew(state, space_id, claim, ttl_ms) do
    ttl_ms = ttl_ms || @ttl_ms
    Process.cancel_timer(claim.timer)
    {timer, token} = arm_ttl(space_id, ttl_ms)

    renewed = %{claim | timer: timer, token: token, ttl_ms: ttl_ms}
    %{state | claims: Map.put(state.claims, space_id, renewed)}
  end

  defp arm_ttl(space_id, ttl_ms) do
    token = make_ref()
    {Process.send_after(self(), {:ttl, space_id, token}, ttl_ms), token}
  end

  defp drop(state, space_id) do
    case Map.fetch(state.claims, space_id) do
      :error ->
        state

      {:ok, claim} ->
        Process.demonitor(claim.ref, [:flush])
        Process.cancel_timer(claim.timer)
        :ets.delete(@table, space_id)
        Phoenix.PubSub.broadcast(Nest.PubSub, topic(space_id), {:space_unlocked, space_id})

        %{state | claims: Map.delete(state.claims, space_id)}
    end
  end

  defp drop_where(state, fun) do
    state.claims
    |> Enum.filter(fn {_space_id, claim} -> fun.(claim) end)
    |> Enum.reduce(state, fn {space_id, _claim}, acc -> drop(acc, space_id) end)
  end
end
