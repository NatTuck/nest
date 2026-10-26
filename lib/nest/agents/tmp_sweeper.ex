defmodule Nest.Agents.TmpSweeper do
  @moduledoc """
  Reclaims scratch directories on the host: dead BEAMs' roots, and this BEAM's
  own leftovers.

  `Nest.Agents.Agent.TmpSpace` gives every BEAM a root, `/tmp/nest/<ospid>`,
  holding one directory per space and one per agent, and marks that root alive by
  writing `.alive` into it. Production is killed rather than stopped, so a BEAM's
  `terminate/2` never runs: without a sweeper every root — and every space and
  agent directory under it — stays until the OS `/tmp` policy removes it (30
  days, and only on hosts that run one).

  So each BEAM sweeps, on a timer, in three passes:

    1. **Dead peer roots.** A direct child of `/tmp/nest` is a *process root*
       iff its name is all digits **and** it contains `.alive` — content, not
       name, which is what keeps a `"none"` space's suggested
       `/tmp/nest/<space-name>` directory out of the running. (A `"none"` space
       can still write a `.alive` there itself, since nothing constrains it; that
       is unenforceable by design, and the directory is then a corpse at any age
       like any other unparseable marker.) A peer root whose `.alive` is older
       than the TTL is removed whole; an `.alive` whose content is not a
       timestamp is a corpse and goes at any age. A child with no `.alive` is not
       a process root and is left alone.
    2. **Our own agent directories with no registered owner.** Under our own
       root, `space-<id>/<name>` goes when no live agent is registered under
       `{space_id, name}` — through the same ownership guard the shell-jobs path
       uses (`TmpSpace.remove_swept/3`), not a second removal implementation.
    3. **Our own space directories with no registered agent and no live job.** A
       `space-<id>` directory goes only when the registry holds no agent in that
       space *and* `Nest.Sandbox.ShellJobs.live_in_space?/1` is false. Pass 2
       runs first, so a space emptied by it goes in the same tick.

  Another BEAM's agents' liveness is unknowable to us, so we never sweep inside a
  live peer's tree — only that BEAM's own sweeper may. That is why pass 1 is by
  timestamp and passes 2 and 3 are by registry: for our own children liveness is
  exactly knowable, and a timestamp is a strictly worse answer to a question we
  can answer directly.

  ## Two things this deliberately does not do

    * **A `"none"` space's scratch is never swept.** It is the host's own
      `/tmp/<agent-name>`, it carries no ownership record beyond the
      `.nest-scratch` marker, and two BEAMs can hold the same name in two
      `"none"` spaces (see `Nest.Agents.Agent.TmpSpace`). There is no safe
      question to ask about it here, so it is left to the agent's own
      `terminate/2`.
    * **The legacy `/tmp/nest-*` roots are not touched**, and nothing here knows
      they exist. They are cleared by hand.

  ## Honest residuals

  The ownership guard is check-then-act, the same window
  `TmpSpace.cleanup_agent_key/3` documents: an incarnation can register between
  the registry read and the `rm_rf`, and then pass 2 removes the directory the
  new agent is about to use. It is bounded because
  `Nest.Sandbox.Mounts.ensure_scratch!/1` re-creates a scratch directory on the
  agent's next command, so the cost is one agent's leftover files, not a broken
  agent.

  A peer's `.alive` is trusted as a timestamp, so a clock that jumped forward
  past the TTL on the sweeping machine would age out a live peer's root. The TTL
  is an hour and the timer is fifteen minutes, so that takes a clock error of
  that size rather than ordinary skew.

  ## Restart

  This process holds no state and is safe to restart: the root is prepared once
  in `Nest.Application.start/2`, never here, so a supervisor restart cannot
  remove a live root. A tick does nothing but `File.ls`, two registry reads, and
  `rm_rf`s of trees Nest wrote, and a message it does not understand is ignored
  rather than crashing it.

  ## Blocking

  This GenServer never blocks for an unknown amount of time. A tick lists a
  directory per root and per space, asks the registry and the shell-jobs
  manager, and `rm_rf`s trees that only Nest wrote. Nothing here waits on an
  agent, a sandbox, an LLM or the network.
  """

  use GenServer

  require Logger

  alias Nest.Agents.Agent.TmpSpace
  alias Nest.Agents.Registry
  alias Nest.FileModes
  alias Nest.Sandbox.ShellJobs

  @name __MODULE__

  # How often to mark and sweep: a fifth of the TTL, so a BEAM that is alive but
  # stalled for a while still re-marks well inside it.
  @tick_ms 15 * 60 * 1000

  # How stale a peer's `.alive` may be before its root is a corpse. An hour is
  # four ticks: long enough that a peer whose timer slipped is not mistaken for
  # dead, short enough that a killed BEAM's tree does not outlive the day.
  @ttl_ms 60 * 60 * 1000

  # The non-agent children a space directory can hold. `.cmds` is
  # `Nest.Sandbox.Paths.stage_dir/1` — staged command transcripts, a sibling of
  # the agent directories on purpose. `project` holds the `tmp`-mode `.nest`
  # mount bind sources (`Nest.ProjectConfig`), which are made under an agent's
  # own scratch directory and so normally go with it; it is skipped here so that
  # a space-level one can never be mistaken for an agent. Only `project` needs
  # saying: `.cmds` is already rejected by `Nest.Name.valid?/1`, and it stays in
  # the list as belt and braces rather than as the load-bearing entry.
  @non_agent_children [".cmds", "project"]

  # ---- Client API ----

  @doc "The registered name this GenServer runs under."
  @spec name() :: atom()
  def name, do: @name

  @spec child_spec() :: Supervisor.child_spec()
  def child_spec do
    %{id: @name, start: {__MODULE__, :start_link, []}, type: :worker}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc """
  Record `now` in `root`'s `.alive`: the timestamp a peer's sweeper reads to
  decide whether this root's owner is still alive.

  `now` is a `DateTime` or a Unix time in milliseconds. A failed write is logged
  and otherwise ignored: the next tick tries again, and a root that cannot be
  marked is a root a peer may age out, not a reason to stop sweeping.
  """
  @spec mark(String.t(), DateTime.t() | integer()) :: :ok
  def mark(root, now \\ DateTime.utc_now()) do
    with {:error, reason} <- TmpSpace.write_alive(root, now) do
      Logger.error("TmpSweeper: could not mark #{root} alive: #{inspect(reason)}")
    end
  end

  @doc """
  Sweep once.

  `own_root` is *this* BEAM's root — the parent and our pid are derived from it —
  `now` is the current time (a `DateTime` or Unix milliseconds) and `ttl_ms` is
  how stale a peer's `.alive` may be before its root counts as a corpse.

  Both are arguments rather than module attributes so the sweep is testable
  without a timer and without sleeping: the timer's only job is to call this.
  """
  @spec sweep(String.t(), DateTime.t() | integer(), non_neg_integer()) :: :ok
  def sweep(own_root, now, ttl_ms) when is_binary(own_root) and is_integer(ttl_ms) do
    now = to_datetime(now)
    parent = Path.dirname(own_root)
    own = Path.basename(own_root)

    Enum.each(list_dir(parent), &sweep_peer_root(parent, &1, own, now, ttl_ms))

    spaces = space_dirs(own_root)
    Enum.each(spaces, &sweep_agents(own_root, &1))
    Enum.each(spaces, &sweep_space(own_root, &1))

    :ok
  end

  # ---- Server callbacks ----

  @impl true
  def init(opts) do
    schedule_tick()

    # The root and the TTL are options rather than constants so the tick itself is
    # testable: a test builds this state with `init/1`, calls
    # `handle_info(:tick, state)` and reads the result, instead of messaging the
    # one registered process — which would sweep this BEAM's *real* root, and with
    # it the scratch of every concurrently running test.
    {:ok,
     %{
       root: Keyword.get_lazy(opts, :root, &TmpSpace.own_root/0),
       ttl_ms: Keyword.get(opts, :ttl_ms, @ttl_ms)
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    # Make the root before marking it. It can be missing — a peer aged us out
    # after a clock error, or `prepare_own_root/0` gave up at boot rather than
    # taking the application down — and without this every tick would log a write
    # failure and nothing would ever recreate it. `mkdir_p` and *not*
    # `prepare_own_root/0`: that one removes the root first, which here would take
    # live scratch with it.
    FileModes.mkdir_p(state.root)
    mark(state.root, now)
    sweep(state.root, now, state.ttl_ms)
    schedule_tick()

    {:noreply, state}
  end

  # See "Restart" in the moduledoc: nothing may crash this process.
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  # ---- Pass 1: dead peer roots ----

  # A child of the parent is a process root iff its name is all digits *and* it
  # holds `.alive`. Both halves matter: the digits keep a `"none"` space's
  # suggested `/tmp/nest/<space-name>` out of the running even if someone dropped
  # an `.alive` in it, and the marker is what distinguishes a root from a
  # directory Nest did not make.
  defp sweep_peer_root(parent, name, own, now, ttl_ms) do
    path = Path.join(parent, name)

    if name != own and process_root_name?(name) and stale?(path, now, ttl_ms) do
      rm_under(parent, path)
    end
  end

  defp process_root_name?(name), do: name != "" and String.match?(name, ~r/\A\d+\z/)

  # No `.alive` at all: not a process root, so not ours to judge. An `.alive` we
  # cannot read, or whose content is not a timestamp, is a corpse — a live
  # sweeper always writes a parseable one.
  defp stale?(root, now, ttl_ms) do
    case File.read(TmpSpace.alive_path(root)) do
      {:ok, content} ->
        case parse_stamp(content) do
          {:ok, at} -> DateTime.diff(now, at, :millisecond) > ttl_ms
          :error -> true
        end

      {:error, _reason} ->
        false
    end
  end

  defp parse_stamp(content) do
    case DateTime.from_iso8601(String.trim(content)) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  # ---- Pass 2: our own agent directories ----

  # `space-<id>` for every space directory under our root. A name that is not
  # that shape is not a space directory, whatever it holds, so it is not a
  # candidate for either pass.
  defp space_dirs(own_root) do
    for name <- list_dir(own_root), {:ok, space_id} <- [space_id(name)] do
      {space_id, Path.join(own_root, name)}
    end
  end

  defp space_id(name) do
    case Regex.run(~r/\Aspace-(-?\d+)\z/, name) do
      [_whole, digits] -> {:ok, String.to_integer(digits)}
      nil -> :error
    end
  end

  # Every child of a space directory that could be an agent's own scratch
  # directory: a valid agent name, and not one of the two things a space
  # directory holds that is not an agent. Removal goes through `TmpSpace`, which
  # owns the ownership guard.
  defp sweep_agents(own_root, {space_id, path}) do
    path
    |> list_dir()
    |> Enum.reject(&(not Nest.Name.valid?(&1) or &1 in @non_agent_children))
    |> Enum.each(fn name ->
      TmpSpace.remove_swept(own_root, Path.join(path, name), {space_id, name})
    end)
  end

  # ---- Pass 3: our own space directories ----

  defp sweep_space(own_root, {space_id, path}) do
    if registered_in_space?(space_id) or live_job_in_space?(space_id) do
      :ok
    else
      rm_under(own_root, path)
    end
  end

  # A `GenServer.call` to the shell-jobs manager *exits* if that manager is
  # restarting, and a crash here would take this process with it for no gain.
  # `true` is the safe answer — it means "do not remove" — and it is also the
  # conservative one: a job we cannot ask about is a job we must assume is live.
  defp live_job_in_space?(space_id) do
    ShellJobs.live_in_space?(space_id)
  catch
    :exit, _reason -> true
  end

  defp registered_in_space?(space_id), do: Registry.list_for_space(space_id) != []

  # ---- Shared helpers ----

  # Every `rm_rf` in this module goes through here, and it asserts that the path
  # is strictly under the root it was given: a stricter guard than SMELLS'
  # identifying-string check, and one that holds even if a caller ever hands over
  # a name `File.ls/1` could not have returned (`..` expands to the parent and is
  # refused).
  defp rm_under(root, path) do
    expanded_root = Path.expand(root)
    expanded = Path.expand(path)

    unless String.starts_with?(expanded, expanded_root <> "/") do
      raise ArgumentError,
            "TmpSweeper: refusing to rm_rf #{inspect(path)}: it is not under #{inspect(root)}"
    end

    File.rm_rf(expanded)
    :ok
  end

  defp list_dir(path) do
    case File.ls(path) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  defp to_datetime(%DateTime{} = now), do: now

  defp to_datetime(unix_ms) when is_integer(unix_ms),
    do: DateTime.from_unix!(unix_ms, :millisecond)
end
