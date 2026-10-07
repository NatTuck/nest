defmodule Nest.HostnameTest do
  @moduledoc """
  Tests for `Nest.Hostname.get/0`.
  """

  # `get/0` reads the global `:nest, :hostname` config, which the root layout
  # also reads via `NestWeb.Layouts.root/1`. Mutating it must not overlap the
  # conn tests that render that layout, so this module runs in the serial
  # phase alongside them.
  use ExUnit.Case, async: false

  alias Nest.Hostname

  describe "get/0" do
    test "returns the configured override" do
      # `config/test.exs` pins the override so tests never depend on the
      # hostname of the machine they run on.
      assert Hostname.get() == "testhost"
    end

    test "falls back to the machine hostname when the override is absent or blank" do
      original = Application.get_env(:nest, :hostname)
      on_exit(fn -> restore_hostname(original) end)

      Application.delete_env(:nest, :hostname)
      unset = Hostname.get()
      assert is_binary(unset) and unset != ""

      Application.put_env(:nest, :hostname, "")
      blank = Hostname.get()
      assert is_binary(blank) and blank != ""
    end
  end

  defp restore_hostname(nil), do: Application.delete_env(:nest, :hostname)
  defp restore_hostname(value), do: Application.put_env(:nest, :hostname, value)
end
