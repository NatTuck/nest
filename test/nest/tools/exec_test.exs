defmodule Nest.Tools.ExecTest do
  use ExUnit.Case, async: true

  test ":erlexec is a declared runtime application, started at boot" do
    # It used to be started lazily, on the first shell command, to keep a boot
    # that never runs one from paying its hardcoded 350ms. That made every
    # command call `Application.ensure_all_started/1` — a global gen_server
    # call on a hot path — and under `--cover` with `max_cases: 16` the
    # controller started exiting callers with `:terminating`, which is why
    # `mix precommit` failed on a busy host with timeouts and exits instead of
    # assertion failures (#145).
    #
    # Both halves are asserted: the `.app` spec says what `mix.exs` decided,
    # and `started_applications/0` says the runtime honoured it. The first is
    # static, so it cannot be perturbed by another test; the second is a
    # postcondition, so it only carries weight when nothing has stopped it.
    assert :erlexec in Application.spec(:nest, :applications)
    assert :erlexec in Enum.map(Application.started_applications(), &elem(&1, 0))
  end
end
