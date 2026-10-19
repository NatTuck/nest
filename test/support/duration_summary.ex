defmodule Nest.Test.DurationSummary do
  @moduledoc """
  Opt-in formatter that reports where the suite's time goes (#94).

  `mix test --slowest` cannot answer this question: it implies `--trace`, which
  runs the suite one test at a time and therefore measures a different run from
  the one we ship. ExUnit does not report per-module or per-test totals in
  parallel mode, and those are the ones that matter, because **ExUnit schedules
  modules, not tests** — `max_cases` bounds how many *modules* run at once, and a
  module's tests run one after another.

  It prints, for the real parallel run:

    * the sum of every test's duration — the suite's measured work;
    * the wall time it was spread over;
    * their ratio, the **effective parallelism**. When that sits far below
      `max_cases`, the slots are blocked rather than busy;
    * the slowest modules (the scheduling unit) and the slowest tests.

  The slowest *tests* are the ones that separate "this really does 700 ms of
  work" from "this was blocked for 700 ms", which are opposite problems.

  Enable with `NEST_TEST_DURATIONS=1`. Off otherwise, so the normal run pays
  nothing for it.
  """

  use GenServer

  @top 20

  @impl true
  def init(_opts), do: {:ok, %{started: nil, modules: %{}, tests: %{}, count: 0, total: 0}}

  @impl true
  def handle_cast({:suite_started, _opts}, state) do
    {:noreply, %{state | started: System.monotonic_time(:microsecond)}}
  end

  def handle_cast({:test_finished, %ExUnit.Test{module: module, name: name, time: us}}, state) do
    {:noreply,
     %{
       state
       | modules: Map.update(state.modules, module, us, &(&1 + us)),
         tests: Map.put(state.tests, {module, name}, us),
         count: state.count + 1,
         total: state.total + us
     }}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @impl true
  def handle_call(_message, _from, state), do: {:reply, :ok, state}

  # ExUnit stops the formatter when the suite ends, so this reports exactly once.
  @impl true
  def terminate(_reason, state) do
    report(state)
    :ok
  end

  defp report(%{started: nil}), do: :ok

  defp report(state) do
    wall_us = System.monotonic_time(:microsecond) - state.started
    parallel = if wall_us > 0, do: state.total / wall_us, else: 0.0
    write_csv(state)

    IO.puts("""

    ---- duration summary (NEST_TEST_DURATIONS) ----
    tests            #{state.count}
    modules          #{map_size(state.modules)}
    measured work    #{ms(state.total)}  (sum of test durations)
    wall             #{ms(wall_us)}
    effective par.   #{Float.round(parallel, 2)}x  (max_cases is the ceiling)

    ---- slowest modules (the scheduling unit) ----
    """)

    emit(state.modules, fn module, us -> "#{ms(us)}  #{inspect(module)}" end)

    IO.puts("\n---- slowest tests ----\n")

    emit(state.tests, fn {module, name}, us ->
      "#{ms(us)}  #{inspect(module)} #{inspect(name)}"
    end)
  end

  defp emit(map, format) do
    map
    |> Enum.sort_by(fn {_key, us} -> -us end)
    |> Enum.take(@top)
    |> Enum.each(fn {key, us} -> IO.puts("  #{format.(key, us)}") end)
  end

  # A machine-readable dump of every test, so the ranking can be analysed
  # without scraping the human report. Opt-in separately, because it writes a
  # file.
  defp write_csv(state) do
    with path when is_binary(path) <- System.get_env("NEST_TEST_DURATIONS_CSV") do
      body =
        state.tests
        |> Enum.sort_by(fn {_key, us} -> -us end)
        |> Enum.map_join("\n", fn {{module, name}, us} ->
          "#{us}\t#{inspect(module)}\t#{inspect(name)}"
        end)

      File.write!(path, body <> "\n")
      IO.puts("\nwrote #{path}")
    else
      _ -> :ok
    end
  end

  defp ms(us), do: String.pad_leading("#{Float.round(us / 1000, 1)} ms", 10)
end
