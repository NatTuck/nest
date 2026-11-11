defmodule Nest.HostnameTest do
  @moduledoc """
  Tests for the injected `Nest.Hostname.get/2`: the hostname fallback, and the
  instance number the page title carries.

  `get/0` — the only caller that reads the `:nest, :hostname` and
  `:nest, :instance` application env — is covered end to end by
  `NestWeb.PageControllerTest`, which pins the shell's `<title>` and
  `window.NEST_CONFIG.host` to the `"testhost2"` that `config/test.exs` sets.
  That also covers `get/2`'s non-empty override branch and its composition, so
  what is left here is what the pinned config cannot reach: falling back to the
  system hostname, and each arm of the composition on its own.
  """

  # Nothing here touches the `:nest, :hostname` or `:nest, :instance` global —
  # `get/2` takes both as arguments — so this file stays concurrent. The
  # fallback used to be exercised through `Application.put_env/delete_env`, which
  # is why it was serialized.
  use ExUnit.Case, async: true

  alias Nest.Hostname

  describe "get/2" do
    test "falls back to the system hostname when the override is unset or blank" do
      # `nil` and `""` are the two documented spellings of "no usable
      # override", and each catches a different regression: `nil` catches a
      # missing `is_binary` guard, `""` catches `is_binary/1` without the
      # empty-string check.
      unset = Hostname.get(nil, nil)
      assert is_binary(unset) and unset != ""

      blank = Hostname.get("", nil)
      assert is_binary(blank) and blank != ""
    end

    test "appends the instance number, and nothing when there is none" do
      assert Hostname.get("vampire", 2) == "vampire2"
      assert Hostname.get("vampire", 7) == "vampire7"
      assert Hostname.get("vampire", nil) == "vampire"

      # The fallback composes the same way: a machine name the operator cannot
      # choose still gets its instance number, which is the case that matters —
      # two instances of one machine, neither of them configured by hand.
      assert Hostname.get("", 3) == Hostname.get("", nil) <> "3"
    end
  end
end
