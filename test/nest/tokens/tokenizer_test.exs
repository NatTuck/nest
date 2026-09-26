defmodule Nest.Tokens.TokenizerTest do
  @moduledoc """
  Tests for `Nest.Tokens.Tokenizer` — the process-wide cl100k_base
  tokenizer backed by Hugging Face `tokenizers`.

  The tokenizer is loaded once by `Nest.Application` at app start and
  stored in `:persistent_term`, so these tests exercise the loaded
  instance directly (no per-test load).
  """

  use ExUnit.Case, async: true

  alias Nest.Tokens.Tokenizer

  describe "load/0" do
    test "loads the bundled cl100k_base tokenizer and is idempotent" do
      assert :ok = Tokenizer.load()
      assert :ok = Tokenizer.load()
      assert Tokenizer.count("Hello, world!") == 4
    end
  end

  describe "count/1" do
    test "matches known cl100k_base counts" do
      # "Hello, world!" is exactly 4 tokens in cl100k_base.
      assert Tokenizer.count("Hello, world!") == 4
      assert Tokenizer.count("") == 0
      assert Tokenizer.count("hello world") == 2
    end

    test "is additive on independent words" do
      assert Tokenizer.count("hello world") ==
               Tokenizer.count("hello") + Tokenizer.count("world")
    end
  end
end
