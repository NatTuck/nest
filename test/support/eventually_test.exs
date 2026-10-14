defmodule EventuallyTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins the contract of `Eventually.eventually/2`.

  The helper has 73 call sites across 30 files and, until this file, nothing
  asserted either of the two behaviours its own docs describe. Both are easy to
  regress silently:

    * it returns the truthy value **without sleeping first** — a version that
      slept before its first check would still pass every call site's assertion,
      just slower;
    * it raises with the **caller's** budget. An earlier version derived the
      budget from a deadline the check had already run past, so it reported a
      *negative* remainder. That is why the raise takes `timeout` directly
      rather than recomputing it.

  The poll counter is kept in the process dictionary on purpose: the `fun` runs
  in the calling process, so no extra process (and no `start_supervised!`) is
  needed to observe how many times it ran.
  """

  test "returns the truthy value without sleeping first, even with a huge interval" do
    # `interval: 3_000` is the assertion: a helper that slept before its first
    # check would spend 3s here, which blows ExUnit's per-test ceiling (2s after
    # `#21`). So "this test finishes at all" is the property under test, and the
    # return value pins the other half of the contract.
    assert Eventually.eventually(fn -> :the_value end, timeout: 500, interval: 3_000) ==
             :the_value
  end

  test "polls until the condition becomes true, and returns its value" do
    Process.put(:eventually_polls, 0)

    result =
      Eventually.eventually(
        fn ->
          n = Process.get(:eventually_polls) + 1
          Process.put(:eventually_polls, n)
          n >= 3
        end,
        timeout: 500,
        interval: 1
      )

    assert result == true
    assert Process.get(:eventually_polls) == 3
  end

  test "raises with the caller's budget, not a derived remainder" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        Eventually.eventually(fn -> false end, timeout: 37, interval: 1)
      end

    assert error.message =~ "within 37ms"
  end
end
