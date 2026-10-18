defmodule Nest.NameTest do
  @moduledoc """
  The one name rule (`Nest.Name`): the pattern, the byte cap, and the fold that
  brings an arbitrary string up to it.

  The edge cases here are the ones the name migration documents — an all-CJK
  name with no ASCII fold, `..`, a name past the filesystem's component limit,
  and a name that sanitises to nothing — because those are the shapes that
  decide whether a rename is safe.
  """

  use ExUnit.Case, async: true

  alias Nest.Name

  describe "valid?/1" do
    test "accepts lowercase letters, digits, `_` and `-`" do
      for name <- ["nat", "clever-raven", "agent_1", "a", "0", "-leading", "trailing_"] do
        assert Name.valid?(name), name
      end
    end

    test "refuses a capital, which is what makes @Nat and @nat one address" do
      refute Name.valid?("Nat")
      refute Name.valid?("review-prA5")
      refute Name.valid?("café")
    end

    test "refuses everything that is not a single filename component" do
      # `..` would escape the scratch root; `/` would nest; a space would need
      # quoting in every place a name is written.
      for name <- ["..", ".", "a/b", "a b", "a.b", "", "café", "agent\n"] do
        refute Name.valid?(name), inspect(name)
      end
    end

    test "refuses a name past the component limit, and accepts one at it" do
      at_cap = String.duplicate("a", Name.max_bytes())

      assert Name.max_bytes() == 255
      assert Name.valid?(at_cap)
      refute Name.valid?(at_cap <> "a")
    end

    test "is total: anything that is not a binary is not a name" do
      for value <- [nil, 42, :agent, %{}, ["a"]] do
        refute Name.valid?(value), inspect(value)
      end
    end
  end

  describe "sanitize/1" do
    test "folds case and punctuation to a readable name" do
      assert Name.sanitize("Jane Doe") == "jane-doe"
      assert Name.sanitize("review-prA5") == "review-pra5"
      assert Name.sanitize("  padded  ") == "padded"
      assert Name.sanitize("a__b--c") == "a__b--c"
    end

    test "folds accented letters instead of dropping them" do
      # NFD splits the letter from its combining mark, the mark is stripped, and
      # the base letter survives: `Café` is `cafe`, not `caf`.
      assert Name.sanitize("Café ☕") == "cafe"
      assert Name.sanitize("Ünïcode") == "unicode"
    end

    test "returns an empty string when nothing survives the fold" do
      # An all-CJK name has no ASCII fold, and a name of punctuation is all
      # separator. `sanitize/1` does not invent a substitute — `valid?/1` refuses
      # `""`, so a caller that must keep the row supplies its own fallback.
      assert Name.sanitize("日本語") == ""
      assert Name.sanitize("...") == ""
      assert Name.sanitize("") == ""
      assert Name.sanitize("---") == ""
      refute Name.valid?(Name.sanitize("日本語"))
    end

    test "folds `..` to nothing, which is what makes the scratch path safe" do
      assert Name.sanitize("..") == ""
      assert Name.sanitize("../etc") == "etc"
      assert Name.sanitize("a/../b") == "a-b"
    end

    test "never lengthens a name, so it cannot push one past the cap" do
      at_cap = String.duplicate("A", Name.max_bytes())

      sanitized = Name.sanitize(at_cap)

      assert byte_size(sanitized) == Name.max_bytes()
      assert Name.valid?(sanitized)
    end

    test "is idempotent, so a sanitised name is a fixed point" do
      for name <- ["Jane Doe", "Café ☕", "review-prA5", "..", "日本語"] do
        once = Name.sanitize(name)
        assert Name.sanitize(once) == once, name
      end
    end

    test "leaves nil nil — a missing name is not an empty one" do
      assert Name.sanitize(nil) == nil
    end
  end
end
