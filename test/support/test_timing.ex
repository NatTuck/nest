defmodule Nest.TestTiming do
  @moduledoc """
  ExUnit formatter that prints exactly one machine-readable timing line.

  `scripts/precommit-test.sh` runs the suite with this formatter *in addition
  to* `ExUnit.CLIFormatter`, and uses the line to split a covered run into the
  four budgeted buckets:

    * `setup`  - everything before ExUnit starts: mix boot, `ecto.create`,
      `ecto.migrate`, cover instrumentation, app boot. Measured against a
      wall-clock `T0` that the script puts in the environment, because this
      process cannot see anything that happened before it started.
    * `load`   - test-file compile/require, i.e. `suite_started` up to the
      first test/module event. That is valid because Mix calls
      `ExUnit.async_run/0` *before* it requires the test files, so the first
      event cannot happen until every file has been loaded.
    * `run`    - the tests themselves. ExUnit's own `run` field already
      contains the load (its `start_time` predates the requires, and its
      `load` field is `nil` under `mix test`), so `run = reported - load`.
    * `post`   - cover analyse/export/report plus teardown. This formatter
      cannot see it; the script computes `post = wall - (setup + load + run)`.

  The emitted line is:

      NEST_TEST_TIMING setup_ms=<int> load_ms=<int> run_ms=<int> reported_ms=<int>

  `reported_ms` is the number ExUnit prints as "Finished in X seconds"
  (`load + run`). Any phase that cannot be computed is emitted as `-1`; the
  script treats that as a loud failure rather than a silent pass.

  Two clocks are in play and must not be mixed: `setup` has to compare against
  the script's wall clock, so it uses epoch microseconds, while `load` is a
  duration and uses the monotonic clock.
  """

  use GenServer

  @prefix "NEST_TEST_TIMING"
  @t0_env "NEST_TEST_T0_US"

  @impl GenServer
  def init(_opts) do
    state = %{
      t0_us: t0_us(),
      started_epoch_us: nil,
      started_mono_us: nil,
      first_event_us: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:suite_started, _opts}, state) do
    state = %{
      state
      | started_epoch_us: System.system_time(:microsecond),
        started_mono_us: System.monotonic_time(:microsecond)
    }

    {:noreply, state}
  end

  def handle_cast({:suite_finished, times_us}, state) do
    # The leading newline terminates whatever the other formatter wrote last:
    # the progress dots carry no trailing newline of their own.
    IO.puts("\n" <> line(state, times_us))
    {:noreply, state}
  end

  def handle_cast({event, _payload}, state) when event in [:test_started, :module_started] do
    {:noreply, mark_first_event(state)}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  defp mark_first_event(%{first_event_us: nil} = state) do
    %{state | first_event_us: System.monotonic_time(:microsecond)}
  end

  defp mark_first_event(state), do: state

  defp line(state, times_us) do
    load_ms = load_ms(state)
    reported_ms = reported_ms(times_us)

    "#{@prefix} setup_ms=#{setup_ms(state)} load_ms=#{load_ms} " <>
      "run_ms=#{run_ms(reported_ms, load_ms)} reported_ms=#{reported_ms}"
  end

  defp t0_us do
    with raw when is_binary(raw) <- System.get_env(@t0_env),
         {us, ""} <- Integer.parse(raw) do
      us
    else
      _ -> -1
    end
  end

  defp setup_ms(%{t0_us: t0_us, started_epoch_us: started})
       when t0_us >= 0 and is_integer(started) do
    div(started - t0_us, 1000)
  end

  defp setup_ms(_state), do: -1

  defp load_ms(%{started_mono_us: started, first_event_us: first})
       when is_integer(started) and is_integer(first) do
    div(first - started, 1000)
  end

  defp load_ms(_state), do: -1

  defp reported_ms(%{run: run}) when is_integer(run), do: div(run, 1000)
  defp reported_ms(_times_us), do: -1

  defp run_ms(reported, load) when reported >= 0 and load >= 0, do: reported - load
  defp run_ms(_reported, _load), do: -1
end
