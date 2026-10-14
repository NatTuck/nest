# roundtrip_os.exs — the same round-trip cost curve, but with the load applied
# from OUTSIDE the BEAM.
#
#   MIX_ENV=test mix run tmp/maxcases-ladder/roundtrip_os.exs
#
# Why a second phase: `roundtrip.exs` applies load as N BEAM processes, which
# the scheduler framework preempts fairly, so it only ever produces a BEAM run
# queue ~N-schedulers deep and a round trip stays sub-millisecond even at 97
# queued. The repo's own measurements (`@answer_ms`: p50 926 ms under 48
# burners; the teardown figures under 32-48 burners) use OS-level burners
# instead, and those starve the *schedulers themselves* -- the kernel
# deschedules the threads that would run the BEAM's work. That is a different
# and much more damaging condition, and it is the one the suite actually meets
# when it is run on a busy machine.
#
# Ops and output shape are identical to `roundtrip.exs` so the two phases can
# be read side by side.

defmodule RTOs.Server do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil)
  @impl true
  def init(nil), do: {:ok, nil}
  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule RTOs do
  @burner "/tmp/nest-burner.sh"

  def start_burners(0), do: :ok

  def start_burners(n) do
    File.write!(@burner, "while :; do :; done\n")

    System.cmd("bash", [
      "-c",
      "for i in $(seq 1 #{n}); do setsid bash #{@burner} >/dev/null 2>&1 & done"
    ])

    :ok
  end

  # The bracket in the pattern keeps pkill from matching its own command line.
  def stop_burners do
    System.cmd("bash", ["-c", "pkill -f 'nest-burner[.]sh' || true"])
    :ok
  end

  def measure(fun, iters), do: for(_ <- 1..iters, do: elem(:timer.tc(fun), 0))

  # How many burners are actually alive. A row whose actual count is 0 is not
  # evidence about load, whatever the nominal count says.
  def burners_alive do
    {out, _} = System.cmd("bash", ["-c", "pgrep -c -f 'nest-burner[.]sh' || echo 0"])
    String.trim(out)
  end

  def report(host, burners, actual, rq, sched, op, samples) do
    s = Enum.sort(samples)
    n = length(s)

    IO.puts(
      Enum.join(
        [
          host, burners, actual, rq, sched, op, n,
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

Mimic.copy(Nest.Models)
for _ <- 1..20, do: Mimic.stub(Nest.Models, :rescan, fn -> 1 end)

{:ok, srv} = RTOs.Server.start_link(nil)
allowed = spawn(fn -> Process.sleep(:infinity) end)

IO.puts("host\tburners\tburners_actual\trun_queue\tschedulers\top\tsamples\tmean_us\tp50_us\tp99_us\tmax_us")

for n <- [0, 8, 16, 32, 48, 64] do
  RTOs.start_burners(n)
  Process.sleep(2000)

  ops = [
    {"gen_server_call", fn -> GenServer.call(srv, :ping, 30_000) end},
    {"mimic_stub", fn -> Mimic.stub(Nest.Models, :rescan, fn -> 1 end) end},
    {"mimic_allow", fn -> Mimic.allow(Nest.Models, self(), allowed) end},
    {"postgres_query", fn -> Nest.Repo.query("select 1") end}
  ]

  actual = RTOs.burners_alive()

  for {name, fun} <- ops do
    rq = :erlang.statistics(:run_queue)
    sched = :erlang.system_info(:schedulers_online)
    RTOs.report(host, n, actual, rq, sched, name, RTOs.measure(fun, 15))
  end

  RTOs.stop_burners()
  Process.sleep(2000)
end

IO.puts("# loadavg \t#{File.read!("/proc/loadavg") |> String.trim()}")
IO.puts("# schedulers \t#{System.schedulers_online()}")
