defmodule Eventually do
  @moduledoc """
  Helper functions for testing asynchronous operations.
  """

  @doc """
  Repeatedly calls the given function until it returns a truthy value
  or the timeout is reached.

  ## Options

    * `:timeout` - Maximum time to wait in milliseconds (default: 500)
    * `:interval` - Delay between retries in milliseconds (default: 10)

  The 500 ms default is a floor for *new* call sites, not something any existing
  test relies on: every one of the 49 `eventually/2` calls in `test/` (24 files)
  passes its own `:timeout`. A call site that needs a tighter bound — a property
  that must hold within a known short window — still has to pass its own: the
  default will not do it for you.

  ## Examples

      assert eventually(fn -> Agents.get_agent(id) == {:error, :not_found} end, timeout: 500)

      assert eventually(fn ->
        length(Agents.list_agents()) == 0
      end, timeout: 500, interval: 20)

  """
  def eventually(fun, opts \\ []) do
    timeout = opts[:timeout] || 500
    interval = opts[:interval] || 10
    deadline = System.monotonic_time(:millisecond) + timeout

    do_eventually(fun, deadline, interval, timeout)
  end

  defp do_eventually(fun, deadline, interval, timeout) do
    result = fun.()

    cond do
      result ->
        result

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(interval)
        do_eventually(fun, deadline, interval, timeout)

      true ->
        # Report the budget the caller asked for. Deriving it from the deadline
        # reported a negative remainder, because the check above has already run
        # the clock past it.
        raise ExUnit.AssertionError,
          message: "Expected condition to become true within #{timeout}ms"
    end
  end
end
