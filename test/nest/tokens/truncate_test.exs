defmodule Nest.Tokens.TruncateTest do
  @moduledoc """
  Tests for `Nest.Tokens.Truncate`.

  Covers:
  - head/2 binary slicing at the token/byte boundary
  - note/2 string formatting with original/kept counts
  - head_with_note/3 combined truncation
  - edge cases: empty string, nil, non-binary input
  """

  use ExUnit.Case, async: true

  alias Nest.Tokens.Truncate

  describe "head/2" do
    test "returns content unchanged when it already fits" do
      content = "Hello, world!"
      assert Truncate.head(content, 100) == content
    end

    test "truncates at the byte boundary when content exceeds budget" do
      content = String.duplicate("a", 1000)
      # 100 tokens * 4 bytes/token = 400 byte cap
      result = Truncate.head(content, 100)
      assert byte_size(result) == 400
    end

    test "handles empty content" do
      assert Truncate.head("", 100) == ""
    end

    test "handles zero budget" do
      result = Truncate.head("hello", 0)
      assert result == ""
    end

    test "handles non-binary input" do
      assert Truncate.head(nil, 100) == ""
      assert Truncate.head(123, 100) == ""
    end

    test "exact fit returns content unchanged" do
      # 10 tokens * 4 bytes = 40 bytes
      content = String.duplicate("a", 40)
      assert Truncate.head(content, 10) == content
    end
  end

  describe "note/2" do
    test "includes original and kept token counts" do
      note = Truncate.note("hello world", 5)
      assert note =~ "truncated"
      assert note =~ "kept first ~5 tokens"
    end

    test "handles non-binary input" do
      assert Truncate.note(nil, 5) == "\n\n[truncated]"
    end
  end

  describe "head_with_note/3" do
    test "returns truncated content and note" do
      content = String.duplicate("a", 1000)
      {kept, note} = Truncate.head_with_note(content, 100, 40)

      assert byte_size(kept) <= (100 - 40) * 4
      assert note =~ "truncated"
      assert note =~ "kept first"
    end

    test "keeps content unchanged when it fits" do
      content = "short content"
      {kept, note} = Truncate.head_with_note(content, 100, 40)
      assert kept == content
      assert note =~ "truncated"
    end

    test "default note tokens is 40" do
      content = String.duplicate("x", 1000)
      {kept, _} = Truncate.head_with_note(content, 100)
      # Kept budget = 100 - 40 = 60 tokens = 240 bytes
      assert byte_size(kept) == 240
    end
  end
end
