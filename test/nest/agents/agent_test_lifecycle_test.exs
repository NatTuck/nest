defmodule Nest.Agents.AgentTestLifecycleTest do
  use Nest.DataCase, async: true

  alias Nest.Agents.AgentTestLifecycle

  describe "reraise_after_teardown/3" do
    test "re-raises every failure kind with the original stacktrace" do
      # A stacktrace that cannot have come from the re-raise site, so the
      # assertion can tell "re-raised with the caller's trace" apart from
      # "raised anew here".
      stacktrace = [{__MODULE__, :probe, 0, [file: ~c"probe.ex", line: 7]}]

      try do
        AgentTestLifecycle.reraise_after_teardown(
          :error,
          RuntimeError.exception("boom"),
          stacktrace
        )
      rescue
        error ->
          assert Exception.message(error) == "boom"
          # The re-raise must carry the caller's frame, not its own.
          assert [{__MODULE__, :probe, 0, _} | _] = __STACKTRACE__
      end

      # `reraise/2` only handles `:error`; the wrapped test bodies can fail
      # with `:throw`/`:exit` too, so this must carry those through as well.
      assert catch_throw(AgentTestLifecycle.reraise_after_teardown(:throw, :ball, stacktrace)) ==
               :ball

      assert catch_exit(AgentTestLifecycle.reraise_after_teardown(:exit, :boom, stacktrace)) ==
               :boom
    end
  end
end
