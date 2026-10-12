defmodule Nest.HostnameTest do
  @moduledoc """
  Tests for `Nest.Hostname.get/0` and the injected `Nest.Hostname.get/1`.
  """

  # `get/0` reads the `:nest, :hostname` application env, which the root layout
  # also reads (`root.html.heex`). *Reading* it concurrently is fine — the
  # problem was *mutating* it, which the fallback cases used to do with
  # `Application.put_env/delete_env`. They now go through `get/1`, which takes
  # the override directly (the same injected-seam shape as
  # `Nest.Hardware.hpu_device_paths/2`), so this file has no global left and is
  # concurrent. `get/0`'s own read of the real config is still covered below.
  use ExUnit.Case, async: true

  alias Nest.Hostname

  describe "get/0" do
    test "returns the configured override" do
      # `config/test.exs` pins the override so tests never depend on the
      # hostname of the machine they run on.
      assert Hostname.get() == "testhost"
    end
  end

  describe "get/1" do
    test "returns the configured override, falling back to the system hostname when it is unset or blank" do
      assert Hostname.get("vampire") == "vampire"

      unset = Hostname.get(nil)
      assert is_binary(unset) and unset != ""

      blank = Hostname.get("")
      assert is_binary(blank) and blank != ""
    end
  end
end
