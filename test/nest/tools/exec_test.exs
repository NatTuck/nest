defmodule Nest.Tools.ExecTest do
  use ExUnit.Case, async: true

  alias Nest.Tools.Exec

  test "erlexec is not auto-started at boot in test, but ensure_started/0 starts it" do
    # `:erlexec` sleeps a hardcoded 350ms in its `init/1`, so outside prod
    # it is kept out of `nest`'s `applications` (see `mix.exs`) and started
    # lazily on the first shell command instead. Read the loaded `.app`
    # spec (static, unlike `started_applications/0`) so the assertion is
    # independent of which async tests have already used a shell command.
    refute :erlexec in Application.spec(:nest, :applications)

    assert :ok = Exec.ensure_started()
    assert :erlexec in Enum.map(Application.started_applications(), &elem(&1, 0))
  end
end
