defmodule Eventually do
  @moduledoc """
  Helper functions for testing asynchronous operations.
  """

  @doc """
  Repeatedly calls the given function until it returns a truthy value
  or the timeout is reached.

  ## Options

    * `:timeout` - Maximum time to wait in milliseconds (default: 1000)
    * `:interval` - Delay between retries in milliseconds (default: 10)

  ## Examples

      assert eventually(fn -> Agents.get_agent(id) == {:error, :not_found} end)

      assert eventually(fn ->
        length(Agents.list_agents()) == 0
      end, timeout: 500, interval: 20)

  """
  def eventually(fun, opts \\ []) do
    timeout = opts[:timeout] || 10
    interval = opts[:interval] || 10
    deadline = System.monotonic_time(:millisecond) + timeout

    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    result = fun.()

    cond do
      result ->
        result

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(interval)
        do_eventually(fun, deadline, interval)

      true ->
        raise ExUnit.AssertionError,
          message:
            "Expected condition to become true within #{deadline - System.monotonic_time(:millisecond)}ms"
    end
  end
end
