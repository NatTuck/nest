# service_time.exs — the service-time curve of the suite's single-process
# serialization points, as a function of concurrent callers.
#
#   MIX_ENV=test mix run tmp/maxcases-ladder/service_time.exs
#
# The question this answers: when `max_cases` rises, which operations get
# *slower* because they queue on one global process, rather than merely
# sharing CPU? For each operation we measure per-call latency with 1..32
# concurrent callers. A serialization point shows latency growing roughly
# linearly with callers; a plain CPU-sharing cost stays flat.
#
# Ops:
#   gen_server_call   one private GenServer, the baseline shape
#   file_stat_missing File.stat on a missing path (a bare file-server round trip)
#   rm_rf_empty       File.rm_rf of the empty scratch dir an agent leaves behind
#   rm_rf_3files      File.rm_rf of a scratch dir with a few scratch files
#   mimic_stub        Mimic.stub/3 -- what Mimic.Server queues on
#   postgres_query    Nest.Repo.query("select 1")
#
# Also traces :file_server_2 to test, rather than assume, that an operation
# is routed through it: a claim of "spends its time in :file_server" is
# checkable, and an untraced op is not routed there.

defmodule SvcTime.Server do
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, nil)
  @impl true
  def init(nil), do: {:ok, nil}
  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule SvcTime do
  @tmp "/tmp/nest-svc"

  defp t(fun) do
    {us, _} = :timer.tc(fun)
    us
  end

  defp concurrent(callers, fun) do
    1..callers
    |> Task.async_stream(fun, max_concurrency: callers, timeout: :infinity, ordered: false)
    |> Enum.flat_map(fn
      {:ok, list} -> list
      _ -> []
    end)
  end

  def gen_server_call(callers, iters) do
    {:ok, pid} = SvcTime.Server.start_link(nil)
    concurrent(callers, fn _ -> for _ <- 1..iters, do: t(fn -> GenServer.call(pid, :ping) end) end)
  end

  def file_stat(callers, iters) do
    concurrent(callers, fn _ ->
      for _ <- 1..iters, do: t(fn -> File.stat(@tmp <> "/definitely-missing") end)
    end)
  end

  # Each caller pre-creates its directories (untimed), then times only the
  # removals -- so the curve measures rm_rf, not mkdir.
  def rm_rf(callers, iters, files) do
    concurrent(callers, fn i ->
      dirs =
        for k <- 1..iters do
          d = "#{@tmp}/#{i}-#{k}-#{:erlang.unique_integer([:positive])}"
          File.mkdir_p!(d)
          for f <- 1..files, do: File.write!("#{d}/f#{f}.txt", "scratch")
          d
        end

      for d <- dirs, do: t(fn -> File.rm_rf(d) end)
    end)
  end

  def mimic_stub(callers, iters) do
    concurrent(callers, fn _ ->
      for _ <- 1..iters, do: t(fn -> Mimic.stub(Nest.Models, :rescan, fn -> 1 end) end)
    end)
  end

  # Same server as stub; the suite's failing tests call both.
  def mimic_allow(callers, iters) do
    owner = self()
    allowed = spawn(fn -> Process.sleep(:infinity) end)

    concurrent(callers, fn _ ->
      for _ <- 1..iters, do: t(fn -> Mimic.allow(Nest.Models, owner, allowed) end)
    end)
  rescue
    _ -> []
  end

  def postgres(callers, iters) do
    concurrent(callers, fn _ ->
      for _ <- 1..iters, do: t(fn -> Nest.Repo.query("select 1") end)
    end)
  end

  def report(host, op, callers, samples) do
    if samples == [] do
      IO.puts("#{host}\t#{op}\t#{callers}\t0\t-1\t-1\t-1\t-1")
    else
      s = Enum.sort(samples)
      n = length(s)
      IO.puts(
        Enum.join(
          [
            host, op, callers, n,
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

  # Does this operation actually route through :file_server_2? Returns the
  # number of messages the file server received while `fun` ran.
  def traced_calls(fun) do
    case Process.whereis(:file_server_2) do
      nil ->
        -1

      fs ->
        :erlang.trace(fs, true, [:receive])
        fun.()
        :erlang.trace(fs, false, [:receive])
        drain(0)
    end
  end

  defp drain(n) do
    receive do
      {:trace, _, :receive, _} -> drain(n + 1)
    after
      0 -> n
    end
  end
end

{:ok, hn} = :inet.gethostname()
host = to_string(hn)
File.mkdir_p!("/tmp/nest-svc")

# Mimic needs the module copied before it can be stubbed; test_helper does this
# at suite startup, and we are not running under test_helper.
Mimic.copy(Nest.Models)

# Warm Mimic up: the very first stub pays a one-off proxy/copy cost (~70 ms),
# which is not a property of the serialization point.
for _ <- 1..20, do: Mimic.stub(Nest.Models, :rescan, fn -> 1 end)

IO.puts("host\top\tcallers\tsamples\tmean_us\tp50_us\tp99_us\tmax_us")

for c <- [1, 2, 4, 8, 16, 32] do
  SvcTime.report(host, "gen_server_call", c, SvcTime.gen_server_call(c, 300))
  SvcTime.report(host, "file_stat_missing", c, SvcTime.file_stat(c, 300))
  SvcTime.report(host, "rm_rf_empty", c, SvcTime.rm_rf(c, 50, 0))
  SvcTime.report(host, "rm_rf_3files", c, SvcTime.rm_rf(c, 50, 3))
  SvcTime.report(host, "mimic_stub", c, SvcTime.mimic_stub(c, 300))
  SvcTime.report(host, "mimic_allow", c, SvcTime.mimic_allow(c, 300))
  SvcTime.report(host, "postgres_query", c, SvcTime.postgres(c, 300))
end

IO.puts("# --- :file_server_2 reachability probe (messages received during 200 ops) ---")
{:ok, pid} = SvcTime.Server.start_link(nil)

IO.puts("# rm_rf_empty     \t#{SvcTime.traced_calls(fn -> Enum.each(1..200, fn i -> d = "/tmp/nest-svc/probe#{i}"; File.mkdir_p!(d); File.rm_rf(d) end) end)}")
IO.puts("# file_stat       \t#{SvcTime.traced_calls(fn -> Enum.each(1..200, fn _ -> File.stat("/tmp/nest-svc/missing") end) end)}")
IO.puts("# gen_server_call \t#{SvcTime.traced_calls(fn -> Enum.each(1..200, fn _ -> GenServer.call(pid, :ping) end) end)}")
IO.puts("# postgres_query  \t#{SvcTime.traced_calls(fn -> Enum.each(1..200, fn _ -> Nest.Repo.query("select 1") end) end)}")
IO.puts("# load1 \t#{elem(Float.parse(File.read!("/proc/loadavg") |> String.split(" ") |> hd()), 0)}")
