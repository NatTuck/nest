# roundtrip.exs — the cost of ONE blocking round trip as a function of the
# number of RUNNABLE processes.
#
#   MIX_ENV=test mix run tmp/maxcases-ladder/roundtrip.exs
#
# Why this and not a filesystem throughput curve: the serializing process is
# `file_server_2`, and it is a *location*, not a cause. The teardown tail survives removing every
# cross-process call from `Agent.terminate/2` (see `@stop_ms`'s docstring), and
# a pure `Agent.ClientAPI.get_status/2` round trip to an idle agent -- no
# filesystem at all -- measured p50 926 ms / max 1534 ms under 48 CPU burners
# against p50 21 us idle (`@answer_ms`'s docstring). So the dominant term is
# what a blocking round trip costs when the scheduler is saturated.
#
# Independent variable: N busy-loop processes, so the run queue is genuinely
# N deep. Reported alongside each point is `:erlang.statistics(:run_queue)`,
# the actual depth at measurement time, and `schedulers_online`, so the curve
# can be read against the core count rather than against a nominal N.
#
# Ops, all one round trip each:
#   gen_server_call  two processes, one private server -- the `get_status` shape
#   mimic_stub       Mimic.stub/3, one round trip to Mimic.Server
#   mimic_allow      Mimic.allow/3, same server
#   postgres_query   Nest.Repo.query("select 1")
#
# Burners stop by message, not by :kill: a busy loop that also does
# `receive ... after 0` stays runnable and still notices a `:stop`.

defmodule RT.Server do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil)
  @impl true
  def init(nil), do: {:ok, nil}
  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule RT do
  # Busy loop. `receive after 0` keeps it runnable (it never blocks) while
  # still noticing `:stop`, so we never need to kill anything.
  def spin do
    receive do
      :stop -> :ok
    after
      0 -> spin()
    end
  end

  def burners(0), do: []
  def burners(n), do: for(_ <- 1..n, do: spawn(fn -> spin() end))

  def stop(pids), do: Enum.each(pids, &send(&1, :stop))

  def measure(fun, iters) do
    for _ <- 1..iters, do: elem(:timer.tc(fun), 0)
  end

  def report(host, burners, rq, sched, op, samples) do
    s = Enum.sort(samples)
    n = length(s)
    IO.puts(
      Enum.join(
        [
          host, burners, rq, sched, op, n,
          Float.round(Enum.sum(s) / n, 1),
          Enum.at(s, div(n, 2)),
          Enum.at(s, min(n - 1, div(n * 99, 100))),
          List.last(s)
        ],
        "\t"
      )
    )
  end
end

{:ok, hn} = :inet.gethostname()
host = to_string(hn)

# Mimic needs the module copied first; test_helper does that at suite startup
# and we are not running under it. Warm the one-off copy cost away.
Mimic.copy(Nest.Models)
for _ <- 1..20, do: Mimic.stub(Nest.Models, :rescan, fn -> 1 end)

{:ok, srv} = RT.Server.start_link(nil)
allowed = spawn(fn -> Process.sleep(:infinity) end)

IO.puts("host\tburners\trun_queue\tschedulers\top\tsamples\tmean_us\tp50_us\tp99_us\tmax_us")

for n <- [0, 1, 8, 16, 32, 64, 128] do
  pids = RT.burners(n)
  Process.sleep(500)

  ops = [
    {"gen_server_call", fn -> GenServer.call(srv, :ping, 30_000) end},
    {"mimic_stub", fn -> Mimic.stub(Nest.Models, :rescan, fn -> 1 end) end},
    {"mimic_allow", fn -> Mimic.allow(Nest.Models, self(), allowed) end},
    {"postgres_query", fn -> Nest.Repo.query("select 1") end}
  ]

  for {name, fun} <- ops do
    rq = :erlang.statistics(:run_queue)
    sched = :erlang.system_info(:schedulers_online)
    RT.report(host, n, rq, sched, name, RT.measure(fun, 15))
  end

  RT.stop(pids)
  Process.sleep(300)
end

IO.puts("# loadavg \t#{File.read!("/proc/loadavg") |> String.trim()}")
IO.puts("# schedulers \t#{System.schedulers_online()}")
