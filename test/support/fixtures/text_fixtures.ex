defmodule Nest.TextFixtures do
  @moduledoc """
  Helpers for building large text fixtures.

  `tiktoken`'s cl100k_base encoder tokenizes long runs of a single
  character in **quadratic** time (e.g. 50_000 `"y"`s takes ~1.5s,
  while 50_000 bytes of realistic prose takes ~9ms). Fixtures that
  just need "a lot of text" must therefore use varied words.

  `big_text/1` repeats a realistic sentence to exactly `bytes` bytes,
  which tokenizes linearly at roughly 4 bytes/token.
  """

  @sentence "the quick brown fox jumps over the lazy dog. "
  @sentence_bytes byte_size(@sentence)

  @doc """
  Returns a realistic-text string of exactly `bytes` bytes.
  """
  @spec big_text(pos_integer()) :: String.t()
  def big_text(bytes) when is_integer(bytes) and bytes > 0 do
    repeats = div(bytes + @sentence_bytes - 1, @sentence_bytes)
    @sentence |> String.duplicate(repeats) |> binary_part(0, bytes)
  end
end
