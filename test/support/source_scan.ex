defmodule Nest.Test.SourceScan do
  @moduledoc """
  Walk a set of source files concurrently, for the project-wide credo checks.

  `Nest.Credo.Check.NoDrainLoopsTest` and
  `Nest.Credo.Check.SysGetStateNeedsReasonTest` each parse the whole tree with
  `Code.string_to_quoted!/1`. That is pure CPU over ~527 files / 4.2 MB, so a
  sequential scan costs ~260 ms on an idle host and stretches from there under
  suite contention — on a slow host it has missed the suite's per-test deadline
  (`ExUnit.configure(timeout: 3_000)` in `test/test_helper.exs`) and died as an
  `ExUnit.TimeoutError` raised inside `string_to_quoted!/1`, with no diagnostic
  about the source.

  That deadline is a *failure bound*, deliberately set above the 1000 ms fences
  so a fence can report its own failure instead of dying as a bare timeout, and
  it must not be raised to accommodate a slow scan. So the scan gets faster
  instead: the same files, the same parse, the same checks, spread over the
  schedulers rather than taken one at a time.
  """

  @doc """
  Run `fun` on every file in `files`, concurrently, and concatenate the results.

  `fun` takes a path and returns a list; the returned list is the concatenation
  of those results **in `files` order**, so an offender list — and therefore the
  failure message a check prints — is identical from run to run.

  ## Options that matter

    * `ordered: true` — results come back in `files` order, not completion
      order. Without it the message for a real offender would vary run to run.
    * `timeout: :infinity` — `Task.async_stream/3` otherwise applies a 5 s
      per-item timeout, which would abort a slow host's scan with a `Task` exit
      and no explanation. The test's own deadline is the only bound that should
      decide whether the scan is too slow.
    * `max_concurrency: System.schedulers_online/0` — the work is pure CPU, so
      one worker per scheduler is the useful maximum.

  Spreading the work does not add CPU demand — the same 527 parses happen
  either way — it only shortens the window in which the scan can be starved by
  the other tests running beside it. The cost to those tests is the same total
  CPU, delivered over a shorter interval.

  A raise from `fun` — a file that will not parse is the usual case — is
  re-raised in the caller with its original stacktrace, rather than surfacing as
  a task exit. See `run/2`.
  """
  @spec flat_map([Path.t()], (Path.t() -> [term()])) :: [term()]
  def flat_map(files, fun) when is_list(files) and is_function(fun, 1) do
    files
    |> Task.async_stream(&run(fun, &1),
      ordered: true,
      timeout: :infinity,
      max_concurrency: System.schedulers_online()
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, results}} -> results
      {:ok, {:raised, exception, stacktrace}} -> reraise(exception, stacktrace)
      {:exit, reason} -> exit(reason)
    end)
  end

  # A raise inside a task is reported as that task's exit: the task logs an
  # `[error] Task ... terminating` block and the caller is taken down by the
  # link, so a `rescue` in the caller never sees the original exception. A file
  # that will not parse is the usual way these checks fail, so the raise is
  # caught here and carried back as a value, to be re-raised in the caller —
  # where it is a plain raise again, with its original stacktrace.
  #
  # The `{:exit, reason}` clause cannot be reached while `timeout: :infinity`
  # holds, because a task can no longer exit abnormally. It is there so that a
  # future finite timeout reports its reason rather than a `FunctionClauseError`
  # from this `Enum.flat_map/2`.
  defp run(fun, file) do
    {:ok, fun.(file)}
  rescue
    exception -> {:raised, exception, __STACKTRACE__}
  end
end
