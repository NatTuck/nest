defmodule Nest.HpuSandboxTest do
  # Real HPU passthrough needs the host's Gaudi devices and `hl-smi`, so
  # this module is tagged `:hpu` and excluded by default (see
  # `test/test_helper.exs`); run it with `mix test --include hpu`.
  #
  # `async: false` is required: the test temporarily overrides the
  # `:hpu_device_paths` app env (pinned to `[]` in `config/test.exs` for
  # hermetic unit tests) so the sandbox builder detects the real devices.
  use ExUnit.Case, async: false

  alias Nest.Hardware
  alias Nest.Sandbox

  @moduletag :hpu

  test "hl-smi sees the host's HPUs through the sandbox" do
    paths = Hardware.hpu_device_paths("/dev")
    assert paths != [], "no HPU devices detected on this host"

    previous = Application.get_env(:nest, :hpu_device_paths)
    Application.put_env(:nest, :hpu_device_paths, paths)
    on_exit(fn -> Application.put_env(:nest, :hpu_device_paths, previous) end)

    # The workspace is the host /tmp (bound read-write by the default
    # caps); no separate tmp_path, so /tmp is not overlaid.
    assert {:ok, output} = Sandbox.run("hl-smi", System.tmp_dir!(), nil, Sandbox.default_caps())
    assert output =~ "HL-SMI"
  end
end
