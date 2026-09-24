defmodule Nest.TestSupport.AgentTestMacro do
  @moduledoc """
  `ExUnit.Case.test/1,2,3` replacements for `Nest.DataCase` /
  `NestWeb.ChannelCase` that wrap every test body with an in-process
  agent teardown.

  ## Why wrap `test` instead of using `on_exit`

  ExUnit runs `on_exit` callbacks in a separate runner process *after*
  the test process has exited (see `ExUnit.Runner.spawn_test_monitor/4`
  and `ExUnit.OnExitHandler`). The test process is the SQL-sandbox
  connection owner, so by the time `on_exit` runs, the connection is
  already gone. An agent still processing a chat turn would then fail
  its `MessageAppender.append_one/2` insert with a Postgrex
  "owner exited" error.

  Wrapping the body lets the teardown run in the test process, while
  the sandbox connection is still checked out. Every agent the test
  started is discovered (via `Nest.Agents.Registry`, scoped to the
  test's sandbox-visible spaces) and must be idle at that point; they
  are then stopped synchronously before the test exits, so the
  invariant "zero remaining agents for this test" is enforced by
  assertion rather than by cleanup silence. See
  `Nest.Agents.AgentTestLifecycle.stop_test_agents/0` and
  `assert_zero_remaining!/1`.

  The wrapper captures the body's exception (if any) and asserts the
  zero-remaining invariant *after* cleanup, but only re-raises the
  invariant failure when the body itself succeeded — so cleanup can
  never mask the real cause of an already-failing test.
  """

  alias Nest.Agents.AgentTestLifecycle

  @doc "Replacement for `ExUnit.Case.test/1` (not-implemented tests)."
  defmacro test(message) do
    quote line: __CALLER__.line do
      ExUnit.Case.test(unquote(message))
    end
  end

  @doc "Replacement for `ExUnit.Case.test/2`."
  defmacro test(message, do: block) do
    wrapped = wrap(block)

    quote line: __CALLER__.line do
      ExUnit.Case.test(unquote(message), do: unquote(wrapped))
    end
  end

  @doc "Replacement for `ExUnit.Case.test/3` (context pattern)."
  defmacro test(message, var, do: block) do
    wrapped = wrap(block)

    quote line: __CALLER__.line do
      ExUnit.Case.test(unquote(message), unquote(var), do: unquote(wrapped))
    end
  end

  defp wrap(block) do
    quote do
      outcome =
        try do
          {:ok, unquote(block)}
        rescue
          exception -> {:error, :rescue, exception, __STACKTRACE__}
        catch
          kind, reason -> {:error, kind, reason, __STACKTRACE__}
        end

      violations = AgentTestLifecycle.stop_test_agents()

      case outcome do
        {:ok, value} ->
          AgentTestLifecycle.assert_zero_remaining!(violations)
          value

        {:error, :rescue, exception, stacktrace} ->
          reraise(exception, stacktrace)

        {:error, kind, reason, stacktrace} ->
          :erlang.raise(kind, reason, stacktrace)
      end
    end
  end
end
