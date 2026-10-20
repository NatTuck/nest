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
      # `Nest.Application` already loaded the tokenizer at app start, so
      # by the time any test runs it must already be present — that is
      # the premise `Nest.Tokens.Estimator` sizes context windows on, so
      # pin it before reloading. `Nest.Application.start/2` awaits the
      # load before it returns, so this is not a race.
      assert Tokenizer.loaded?()

      # An explicit reload must still work: `load/0` is idempotent and
      # replaces the stored tokenizer with a freshly loaded one.
      assert :ok = Tokenizer.load()
    end
  end

  describe "count/1" do
    test "matches known cl100k_base counts" do
      # "Hello, world!" is exactly 4 tokens in cl100k_base: "Hello", ",",
      # " world", "!". That covers a space-adjacent word token and
      # punctuation, and it would be 5 if special tokens were added.
      assert Tokenizer.count("Hello, world!") == 4

      # The empty boundary, which pins `add_special_tokens: false`: a
      # tokenizer that added them would count 1 here.
      assert Tokenizer.count("") == 0
    end
  end
end
