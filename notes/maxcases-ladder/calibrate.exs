# calibrate.exs — portable speed features for the max_cases rule.
#
# Run on each measured host with:  MIX_ENV=test mix run tmp/maxcases-ladder/calibrate.exs
#
# Purpose: the `max_cases` question is "how much simultaneity can THIS host
# absorb before the suite's serialization points stop keeping up". CPU topology
# cannot see speed, so this measures speed directly, in three parts:
#
#   cpu_us      single-thread throughput on a fixed integer workload (best of 3)
#   ping_idle   GenServer.call round-trip, one caller, sequential
#   ping_mean   per-call latency with 32 concurrent callers on ONE server --
#               the shape of Mimic's single-server stub/allow bottleneck
#   ping_max    worst single call in that loaded run
#   db_us       Postgres round-trip, best effort
#
# Everything here uses only the project's own dependencies: no /usr/bin/time,
# no external binary, nothing that can be missing on a host.

defmodule MaxCasesCal.Server do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil)
  @impl true
  def init(nil), do: {:ok, nil}
  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule MaxCasesCal do
  @cpu_n 200_000
  @pings 400
  @callers 32

  # Fixed integer workload; the result is folded into an accumulator so it
  # cannot be optimised away.
  def cpu_rounds(n), do: Enum.reduce(1..n, 0, fn i, acc -> rem(acc + i * i + 7, 1_000_003) end)

  def cpu_us do
    cpu_rounds(10_000)
    Enum.min(for _ <- 1..3, do: elem(:timer.tc(fn -> cpu_rounds(@cpu_n) end), 0))
  end

  def ping_idle_us(pid) do
    Enum.each(1..50, fn _ -> GenServer.call(pid, :ping) end)
    us = for _ <- 1..@pings, do: elem(:timer.tc(fn -> GenServer.call(pid, :ping) end), 0)
    (Enum.sum(us) / length(us)) |> Float.round(1)
  end

  # One server, @callers concurrent callers: this is the queueing shape that
  # produces "Mimic.stub timed out" on a slow host.
  def ping_loaded_us(pid) do
    samples =
      1..@callers
      |> Task.async_stream(
        fn _ ->
          for _ <- 1..@pings, do: elem(:timer.tc(fn -> GenServer.call(pid, :ping, 60_000) end), 0)
        end,
        max_concurrency: @callers,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, list} -> list end)

    sorted = Enum.sort(samples)
    mean = Float.round(Enum.sum(sorted) / length(sorted), 1)
    max = List.last(sorted)
    {mean, max}
  end

  def db_us do
    case Nest.Repo.query("select 1") do
      {:ok, _} ->
        Enum.each(1..5, fn _ -> Nest.Repo.query("select 1") end)
        us = for _ <- 1..50, do: elem(:timer.tc(fn -> Nest.Repo.query("select 1") end), 0)
        (Enum.sum(us) / length(us)) |> Float.round(1)

      {:error, reason} ->
        "error:#{inspect(reason) |> String.slice(0, 40)}"
    end
  rescue
    e -> "error:#{inspect(e.__struct__)}"
  end

  def cpuinfo(key) do
    case Regex.run(~r/^#{key}\s*:\s*(.+)$/m, File.read!("/proc/cpuinfo")) do
      [_, v] -> String.trim(v)
      _ -> "?"
    end
  end

  def topology do
    logical = System.schedulers_online()
    sib = cpuinfo("siblings") |> Integer.parse() |> elem_or_nil()
    cores = cpuinfo("cpu cores") |> Integer.parse() |> elem_or_nil()

    real =
      if is_integer(sib) && is_integer(cores) && sib > 0 && cores > 0,
        do: div(logical, div(sib, cores)),
        else: logical

    {logical, sib, cores, real, cpuinfo("model name")}
  end

  defp elem_or_nil({n, _}), do: n
  defp elem_or_nil(_), do: nil
end

{:ok, pid} = MaxCasesCal.Server.start_link(nil)
{logical, sib, cores, real, model} = MaxCasesCal.topology()
cpu = MaxCasesCal.cpu_us()
idle = MaxCasesCal.ping_idle_us(pid)
{loaded_mean, loaded_max} = MaxCasesCal.ping_loaded_us(pid)
db = MaxCasesCal.db_us()

defmodule MaxCasesCal.Host do
  def name do
    {:ok, hn} = :inet.gethostname()
    to_string(hn)
  end
end

IO.puts("host\tlogical\tsiblings\tcpu_cores\treal_cpus\tcpu_us\tping_idle_us\tping_load_mean_us\tping_load_max_us\tdb_us\tmodel")
IO.puts(
  Enum.join(
    [MaxCasesCal.Host.name(), logical, sib, cores, real, cpu, idle, loaded_mean, loaded_max, db, model],
    "\t"
  )
)
