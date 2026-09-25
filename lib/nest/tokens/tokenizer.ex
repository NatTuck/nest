defmodule Nest.Tokens.Tokenizer do
  @moduledoc """
  Process-wide tokenizer for the `cl100k_base` encoding.

  Backed by Hugging Face `tokenizers` rather than `tiktoken`. The
  `tiktoken` NIF stores its BPE vocabulary in Rust `thread_local!`
  state, so every dirty CPU scheduler thread that handles a call
  pays a one-time ~200ms vocabulary build. `tokenizers` exposes the
  tokenizer as a shared Rust resource, so the vocabulary is built
  once and reused across all scheduler threads.

  The tokenizer is loaded once at application start (see
  `Nest.Application`) and stored in `:persistent_term`, which makes
  `count/1` a lock-free read with no per-call load and no DB.

  This module never blocks: the tokenizer is already loaded, and
  `Tokenizers.Tokenizer.encode/3` runs on a dirty CPU scheduler
  inside the NIF.
  """

  @tokenizer_json "priv/tokenizers/cl100k_base.json"
  @key {__MODULE__, :cl100k_base}

  @doc """
  Load the bundled cl100k_base tokenizer into `:persistent_term`.

  Called once from the application supervisor. Idempotent — calling
  it again replaces the stored tokenizer with a freshly loaded one.
  """
  @spec load() :: :ok
  def load do
    path = Path.join(:code.priv_dir(:nest), Path.relative_to(@tokenizer_json, "priv"))

    {:ok, tokenizer} = Tokenizers.Tokenizer.from_file(path)
    :persistent_term.put(@key, tokenizer)
    :ok
  end

  @doc false
  @spec count(String.t()) :: non_neg_integer()
  def count(text) when is_binary(text) do
    {:ok, encoding} =
      Tokenizers.Tokenizer.encode(tokenizer(), text, add_special_tokens: false)

    Tokenizers.Encoding.get_length(encoding)
  end

  defp tokenizer do
    :persistent_term.get(@key, nil) ||
      raise ArgumentError,
            "Nest.Tokens.Tokenizer has not been loaded; call Nest.Tokens.Tokenizer.load/0"
  end
end
