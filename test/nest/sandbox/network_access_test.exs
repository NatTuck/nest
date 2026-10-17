defmodule Nest.Sandbox.NetworkAccessTest do
  @moduledoc """
  The network's injection point: the space's value reaches the resolved caps as
  `"net"`, and it is authoritative — a mode's own `net` is dead data.
  """

  use ExUnit.Case, async: true

  alias Nest.ProjectConfig
  alias Nest.Sandbox
  alias Nest.Sandbox.Mounts

  import ExUnit.CaptureLog

  defp caps_with_net(net) do
    %{"net" => net, "fs" => %{"read" => ["/"], "write" => []}}
  end

  defp mounts(network_access), do: Mounts.new(nil, nil, "bwrap", 7, network_access)

  describe "with_network_access/2" do
    test "puts the mounts' value in, overriding the mode's" do
      assert Sandbox.with_network_access(caps_with_net(false), mounts(true))["net"] == true
      assert Sandbox.with_network_access(caps_with_net(true), mounts(false))["net"] == false
    end

    test "is false for a value that names no space" do
      # `default_caps/0`'s value: an agent with no space behind it must not gain
      # the network.
      assert Sandbox.with_network_access(caps_with_net(true), Mounts.new(nil, nil))["net"] ==
               false

      assert Sandbox.with_network_access(caps_with_net(true), Mounts.new(nil, nil))["net"] ==
               Sandbox.default_caps()["net"]
    end
  end

  describe "resolve_caps/2" do
    test "injects the space's value, so every caps resolution gets it" do
      # Both resolution paths (`Agent.resolve_caps/1` and
      # `ChatPipeline.resolve_mode_and_caps/3`) end here, which is what makes this
      # the one injection point rather than two copies.
      assert ProjectConfig.resolve_caps(caps_with_net(false), mounts(true))["net"] == true
    end

    test "injects it even when the project config is malformed" do
      # The `.nest` failure path returns the caps unchanged, so injecting after
      # the merge would silently drop the network — and `Caps.validate/1` would
      # then reject the caps for having no `"net"` at all.
      dir = Path.join(System.tmp_dir!(), "nest_net_cfg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".nest"), "not [valid")
      on_exit(fn -> if String.contains?(dir, "nest_net_cfg_"), do: File.rm_rf(dir) end)

      log =
        capture_log(fn ->
          caps =
            ProjectConfig.resolve_caps(
              caps_with_net(false),
              Mounts.new(dir, nil, "bwrap", 7, true)
            )

          assert caps["net"] == true
        end)

      assert log =~ "ignoring"
    end
  end

  describe "the resolved caps reach the sandbox" do
    test "a mode declaring net: false in a space with network access gets --share-net" do
      # The whole point of the change: the mode's `net` is ignored, so the space's
      # value is what the sandbox acts on.
      dir =
        Path.join([
          File.cwd!(),
          "_build",
          "tmp",
          "nest_net_build_#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(dir)
      on_exit(fn -> if String.contains?(dir, "nest_net_build_"), do: File.rm_rf(dir) end)

      caps =
        ProjectConfig.resolve_caps(
          caps_with_net(false),
          Mounts.new(dir, nil, "bwrap", 7, true)
        )

      {:ok, args} = Sandbox.build(caps, Mounts.new(dir, nil, "bwrap", 7, true))

      assert "--share-net" in args
      refute "--unshare-net" in args
    end
  end
end
