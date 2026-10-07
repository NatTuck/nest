defmodule Nest.Tools.ExecTest do
  use ExUnit.Case, async: true

  alias Nest.Tools.Exec

  test "erlexec is not auto-started in test, and ensure_started/0 starts it" do
    # `:erlexec` sleeps a hardcoded 350ms in its `init/1`, so the test env
    # keeps it out of `nest`'s `applications` (see `mix.exs`) and starts it
    # lazily on the first shell command instead.
    #
    # The `.app` spec is read statically, unlike `started_applications/0`:
    # it is what `mix.exs` decided, and another test having already run a
    # shell command cannot perturb it. The `started_applications/0`
    # assertion below is a postcondition, so it only carries weight when
    # this test runs before any shell command in the same VM.
    refute :erlexec in Application.spec(:nest, :applications)

    assert :ok = Exec.ensure_started()
    assert :erlexec in Enum.map(Application.started_applications(), &elem(&1, 0))

    # Documented as idempotent and cheap once running, so a second call
    # must neither raise nor restart anything.
    assert :ok = Exec.ensure_started()
  end
end
