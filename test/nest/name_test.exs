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

    test "refuses everything outside the class, a capital and a path escape alike" do
      # `..` would escape the scratch root; `/` would nest; a space would need
      # quoting in every place a name is written; a capital is what would make
      # `@Nat` and `@nat` two addresses for one human.
      for name <- ["Nat", "..", ".", "a/b", "a b", "a.b", "", "café", "agent\n"] do
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
      # One representative per shape — the absent value and a non-string scalar
      # — because every non-binary takes the same `is_binary/1` refusal.
      for value <- [nil, 42] do
        refute Name.valid?(value), inspect(value)
      end
    end
  end

  describe "sanitize/1" do
    test "folds case, punctuation and accented letters to a readable name" do
      # NFD splits an accented letter from its combining mark, the mark is
      # stripped, and the base letter survives: `Café` is `cafe`, not `caf`. A
      # run of allowed characters is left alone.
      assert Name.sanitize("Jane Doe") == "jane-doe"
      assert Name.sanitize("Café ☕") == "cafe"
      assert Name.sanitize("a__b--c") == "a__b--c"
    end

    test "returns an empty string when nothing survives the fold" do
      # An all-CJK name has no ASCII fold, and a name of punctuation is all
      # separator. `sanitize/1` does not invent a substitute — `valid?/1` refuses
      # `""`, so a caller that must keep the row supplies its own fallback.
      assert Name.sanitize("日本語") == ""
      assert Name.sanitize("...") == ""
      assert Name.sanitize("") == ""
    end

    test "folds `..` to nothing, which is what makes the scratch path safe" do
      assert Name.sanitize("..") == ""
      assert Name.sanitize("../etc") == "etc"
      assert Name.sanitize("a/../b") == "a-b"
    end

    test "never lengthens a name in bytes, so it cannot push one past the cap" do
      # The trivial ASCII case, then the two mechanisms that could lengthen a
      # name: NFD decomposition (one 2-byte `é` becomes two codepoints, but the
      # combining mark is stripped) and Hangul (one syllable becomes three jamo,
      # which are not `[a-z0-9]` and collapse into one `-`).
      inputs = [
        String.duplicate("A", Name.max_bytes()),
        String.duplicate("é", 127),
        "agent" <> String.duplicate("각", 100)
      ]

      for input <- inputs do
        sanitized = Name.sanitize(input)

        assert byte_size(sanitized) <= byte_size(input), inspect(input)
        assert Name.valid?(sanitized), inspect(input)
      end

      assert Name.sanitize(String.duplicate("A", Name.max_bytes())) ==
               String.duplicate("a", Name.max_bytes())

      assert Name.sanitize(String.duplicate("é", 127)) == String.duplicate("e", 127)
    end

    test "is idempotent, but trims an edge dash even from a valid name" do
      for name <- ["Jane Doe", "Café ☕", "review-prA5", "..", "日本語", "-nat", "nat-"] do
        once = Name.sanitize(name)
        assert Name.sanitize(once) == once, name
      end

      # `valid?/1` allows a dash on the edge, but `sanitize/1` trims it, so a
      # valid name is not necessarily a fixed point of the fold.
      assert Name.valid?("-nat")
      assert Name.sanitize("-nat") == "nat"
      assert Name.sanitize("nat-") == "nat"
    end

    test "leaves nil nil — a missing name is not an empty one" do
      assert Name.sanitize(nil) == nil
    end
  end
end
