defmodule Nest.Agents.GateProbeTest do
  @moduledoc """
  TEMPORARY PROBE — Step 1 of the teardown-gate work. Not a pin, deleted before
  the fix lands.

  Measures the `stop_pid/2` handshake for agents that are provably idle, while
  the schedulers are saturated by CPU burners. The question it answers is the
  one the existing guard cannot answer: when an idle agent misses `@stop_ms`,
  is the agent doing something, or was it merely not scheduled?

  Results are written to a file rather than printed, so the probe adds no
  console output to the suite.
  """

  # `async: false` because the probe deliberately saturates every scheduler with
  # burners; running it alongside other tests would make its own load
  # unpredictable and would slow unrelated tests to a crawl.
  use Nest.DataCase, async: false

  alias Nest.Agents.AgentTestHelpers
  alias Nest.Agents.AgentTestLifecycle

  @burners_default 32
  @agents 12
  @out_dir "notes/test-runs"

  test "stop handshake for idle agents under burner load" do
    burners = String.to_integer(System.get_env("GATE_PROBE_BURNERS", "#{@burners_default}"))
    run = System.os_time(:millisecond)
    flags = :atomics.new(1, signed: false)
    _burners = Enum.map(1..burners//1, fn _ -> spawn_burner(flags) end)

    # Every agent is started and left alone: no turn, no tool call, nothing
    # parked. They are parked in their own receive loops, which is exactly the
    # state `stop_pid/2`'s comment says a compliant test leaves them in.
    _agents = for _ <- 1..@agents, do: AgentTestHelpers.start_agent()

    result = AgentTestLifecycle.stop_test_agents()

    :atomics.put(flags, 1, 1)

    report = [
      "run=#{run}",
      "burners=#{burners} agents=#{@agents} owned=#{result.owned}",
      "in_flight=#{inspect(result.in_flight)}",
      "not_stopped=#{inspect(result.not_stopped)}",
      "samples_us=#{inspect(Enum.map(result.diag, fn {_s, _n, _sample, us, _info} -> us end))}",
      "samples=#{inspect(result.diag, limit: :infinity, printable_limit: 4000)}"
    ]

    File.write!("#{@out_dir}/gate-probe-#{burners}.txt", Enum.join(report, "\n") <> "\n")

    assert result.owned == @agents
  end

  defp spawn_burner(flags) do
    spawn(fn ->
      loop_until(flags)
    end)
  end

  defp loop_until(flags) do
    if :atomics.get(flags, 1) == 0 do
      _ = Enum.reduce(1..200, 0, &(&1 + &2))
      loop_until(flags)
    else
      :ok
    end
  end
end
