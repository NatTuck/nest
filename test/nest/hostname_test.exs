defmodule Nest.HostnameTest do
  @moduledoc """
  Tests for the fallback in the injected `Nest.Hostname.get/1`.

  `get/0` — the only caller that reads the `:nest, :hostname` application env —
  is covered end to end by `NestWeb.PageControllerTest`, which pins the shell's
  `<title>` and `window.NEST_CONFIG.host` to the `"testhost"` that
  `config/test.exs` sets. That also covers `get/1`'s non-empty override branch,
  so what is left here is the one path the pinned config cannot reach: falling
  back to the system hostname.
  """

  # Nothing here touches the `:nest, :hostname` global — `get/1` takes the
  # override as an argument — so this file stays concurrent. The fallback used
  # to be exercised through `Application.put_env/delete_env`, which is why it
  # was serialized.
  use ExUnit.Case, async: true

  alias Nest.Hostname

  describe "get/1" do
    test "falls back to the system hostname when the override is unset or blank" do
      # `nil` and `""` are the two documented spellings of "no usable
      # override", and each catches a different regression: `nil` catches a
      # missing `is_binary` guard, `""` catches `is_binary/1` without the
      # empty-string check.
      unset = Hostname.get(nil)
      assert is_binary(unset) and unset != ""

      blank = Hostname.get("")
      assert is_binary(blank) and blank != ""
    end
  end
end
