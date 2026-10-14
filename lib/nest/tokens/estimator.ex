defmodule Nest.Tokens.Estimator do
  @moduledoc """
  Token estimation for the LLM context budget.

  Counts tokens for strings, message lists, and tool results using
  the `cl100k_base` encoding (the encoding used by GPT-3.5/GPT-4 and
  a reasonable proxy for Anthropic Claude's tokenizer — typically
  within 5-10% for mixed text).

  All public functions return a **conservative upper bound** on token
  count by applying a 20% safety multiplier to the real cl100k_base
  count. This is intentional: when the Estimator is used to decide
  whether a message will fit in a context window, false positives
  (refusing a call that would have fit) are worse than false
  negatives (letting a too-big call through and truncating it).

  Use `raw_count/1` if you need the actual token count without the
  safety multiplier (e.g. for telemetry or display).

  ## Encoding choice

  We use `cl100k_base` because:

    * It's the encoding OpenAI uses for GPT-3.5 and GPT-4, so its
      counts are exact for those models.
    * It's a reasonable proxy for Anthropic Claude's tokenizer
      (typically within 5-10% for English text).
    * It's the most commonly benchmarked encoding for general text.

  For models that use `o200k_base` (GPT-4o, etc.) the count is
  approximate but still in the right ballpark.
  """

  alias Nest.Messages.Assistant
  alias Nest.Messages.Message
  alias Nest.Messages.Part
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.User
  alias Nest.Tokens.Tokenizer

  # 20% safety multiplier on top of the real cl100k_base count.
  # Applied to every public function in this module.
  @safety_multiplier 1.20

  # Per-message wire-format overhead. The role tag ("system",
  # "user", "assistant", "tool"), JSON delimiters, message
  # wrapper, etc. add a handful of tokens that the raw count
  # misses. We add a flat 10 tokens per message to absorb this.
  @per_message_overhead 10

  @doc """
  Returns the **real** token count for a string using cl100k_base.
  No safety multiplier.

  Useful for telemetry, display, and tests that want to compare
  against a known baseline.

  Content that isn't valid UTF-8 (e.g. raw binary captured from a
  command) can't be tokenized, so we detect it up front and fall back
  to a byte-based estimate — a binary tool result never crashes the
  sizing path.
  """
  @spec raw_count(String.t()) :: pos_integer()
  def raw_count(text) when is_binary(text) do
    if String.valid?(text) do
      count_tokens(text)
    else
      byte_estimate(text)
    end
  end

  def raw_count(_), do: 0

  # cl100k_base count, with a heuristic fallback on a genuine
  # tokenizer failure. `Nest.Tokens.Tokenizer.count/1` reads a
  # pre-loaded tokenizer from `:persistent_term`; the only expected
  # failure is invalid UTF-8, which the caller already filters with
  # `String.valid?/1`. The rescue stays as a safety net for that.
  #
  # An *unloaded* tokenizer is not a tokenization failure and must not
  # fall back. `Nest.Application` loads it concurrently with the
  # supervision tree, and the endpoint binds its listener before the
  # load is awaited, so this is reachable while the tokenizer is still
  # absent. Falling back there returns a `chars/4` count that is quietly
  # wrong — no error, no failing test, just a wrong context budget.
  # Re-raise instead: a boot-ordering bug has to be loud.
  defp count_tokens(text) do
    Tokenizer.count(text)
  rescue
    error ->
      if Tokenizer.loaded?() do
        char_estimate(text)
      else
        reraise error, __STACKTRACE__
      end
  end

  # Invalid-UTF-8 fallback. Byte-based because the standard
  # `chars / 4` heuristic can't run on an invalid binary
  # (`String.length/1` raises on one).
  defp byte_estimate(text), do: div(byte_size(text) + 3, 4)

  # Valid-text fallback when tokenization fails: chars / 4.
  defp char_estimate(text), do: div(String.length(text) + 3, 4)

  @doc """
  Returns a conservative token count for a string.

  Applies a 20% safety multiplier on top of `raw_count/1`. Use this
  for budget checks.
  """
  @spec estimate(String.t()) :: pos_integer()
  def estimate(text) when is_binary(text) do
    text
    |> raw_count()
    |> apply_safety()
    |> Kernel.+(@per_message_overhead)
  end

  def estimate(_), do: @per_message_overhead

  @doc """
  Estimates the token count for content of a known byte size,
  without materializing or tokenizing the content.

  Uses the standard ~4-bytes-per-token heuristic (`byte_estimate/1`)
  plus the safety multiplier and per-message overhead. This is for
  callers that only have a size (e.g. a `stat`ed file) and would
  otherwise have to synthesize a same-size string — which is both
  wasteful and pathological for BPE tokenization on repeated characters.
  """
  @spec estimate_bytes(non_neg_integer()) :: pos_integer()
  def estimate_bytes(size) when is_integer(size) and size >= 0 do
    div(size + 3, 4)
    |> apply_safety()
    |> Kernel.+(@per_message_overhead)
  end

  # Per-part ceiling for binary media, by modality.
  #
  # Token cost is a function of the decoded pixels the provider renders, and
  # every provider downsamples to its own ceiling before billing, so the
  # ceiling is the true upper bound on the model-visible cost — and it is the
  # only bound derivable without decoding the file.
  #
  # Pricing media by byte size would be wrong rather than merely
  # conservative: base64 is ~4 bytes per token at `estimate_bytes/1`'s ratio,
  # so a 1 MB image would price at ~250_000 tokens, roughly 100x its real
  # cost, and the preflight would refuse every image on any real context
  # window. The provider decodes the base64, so its token count is not
  # proportional to the encoded length at all.
  #
  # These are proposed upper bounds, not measurements — measuring them needs
  # real API calls with real images. They are anchored on the providers'
  # documented downsampling limits: Anthropic scales an image so its long edge
  # is <= 1568px and prices by area/750; OpenAI `detail: "high"` scales to
  # 2048x2048 and prices 85 + 170 per 512x512 tile. 4096 is a headroom
  # multiple of both. Keyed by the same vocabulary as `Part.modalities/0`,
  # and a test asserts the two are equal.
  @media_token_ceiling %{image: 4_096}

  # A restored part whose modality this build does not know. Priced at the most
  # expensive media we have any basis for, so an unknown attachment can never
  # make the budget under-count. Deliberately NOT a key of
  # `@media_token_ceiling`: nothing can produce it, and that map is pinned to
  # `Part.modalities/0` by a test.
  @unknown_media_token_ceiling 65_536

  @doc """
  The token ceiling for a media part.
  """
  @spec estimate_media(Part.Media.t()) :: pos_integer()
  def estimate_media(%Part.Media{modality: modality}) when is_atom(modality),
    do: estimate_media_ceiling(modality)

  def estimate_media(%Part.Media{}), do: @unknown_media_token_ceiling

  @doc """
  The token ceiling for a media modality.

  Raises for a modality outside `@media_token_ceiling`. That is deliberate:
  the alternative is the 10-token catch-all in `estimate_part/1`, which would
  price a 1 MB image at 10 and mean the cap never fires. `Part.new_media/1`
  refuses any modality outside `Part.modalities/0`, so the two vocabularies
  cannot drift and this is unreachable.
  """
  @spec estimate_media_ceiling(Part.Media.modality()) :: pos_integer()
  def estimate_media_ceiling(modality), do: Map.fetch!(@media_token_ceiling, modality)

  @doc """
  The media pricing ceilings, keyed by modality. Exposed so a test can
  assert this vocabulary equals `Part.modalities/0`.
  """
  @spec media_token_ceilings() :: %{Part.Media.modality() => pos_integer()}
  def media_token_ceilings, do: @media_token_ceiling

  @doc """
  Returns a conservative token count for a list of messages
  (the canonical `Message.t()` tagged-tuple shape).

  Each message is sized independently and the results are summed.
  The result includes the per-message overhead for every message.
  """
  @spec estimate_messages([Message.t()]) :: pos_integer()
  def estimate_messages(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + estimate_message(msg)
    end)
  end

  def estimate_messages(_), do: 0

  @doc """
  Returns a conservative token count for a single message.
  """
  @spec estimate_message(Message.t()) :: pos_integer()
  def estimate_message({:system, %System{parts: parts}}),
    do: estimate_parts(parts) + @per_message_overhead

  def estimate_message({:user, %User{parts: parts}}),
    do: estimate_parts(parts) + @per_message_overhead

  def estimate_message({:assistant, %Assistant{parts: parts}}),
    do: estimate_parts(parts) + @per_message_overhead

  def estimate_message({:tool, %Tool{parts: parts}}),
    do: estimate_parts(parts) + @per_message_overhead

  def estimate_message(_), do: @per_message_overhead

  @doc """
  Returns a conservative token count for a list of parts.
  """
  @spec estimate_parts([Part.t()]) :: pos_integer()
  def estimate_parts(nil), do: 0
  def estimate_parts([]), do: 0

  def estimate_parts(parts) when is_list(parts) do
    Enum.reduce(parts, 0, fn part, acc ->
      acc + estimate_part(part)
    end)
  end

  def estimate_parts(_), do: 0

  @doc """
  Returns a conservative token count for a single part.
  """
  @spec estimate_part(Part.t()) :: pos_integer()
  def estimate_part(%Part.Text{text: text}), do: estimate(text || "")

  def estimate_part(%Part.Thinking{thinking: text, signature: signature}) do
    estimate(text || "") + if(signature, do: estimate(signature), else: 0)
  end

  def estimate_part(%Part.ToolUse{name: name, arguments: args}) do
    estimate(name || "") + estimate_json(args) + 20
  end

  def estimate_part(%Part.ToolResult{content: content, arguments: args}) do
    estimate(content || "") + estimate_json(args)
  end

  def estimate_part(%Part.Refusal{refusal: text}), do: estimate(text || "")

  def estimate_part(%Part.Media{} = media), do: estimate_media(media)

  def estimate_part(_), do: @per_message_overhead

  # JSON encoding is the closest approximation to what the LLM
  # actually sees. We use Jason for the encoding so the size matches
  # what the LLM provider will tokenize.
  @spec estimate_json(term()) :: pos_integer()
  defp estimate_json(nil), do: 0

  defp estimate_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> estimate(json)
      {:error, _} -> 0
    end
  end

  # Multiplier: ceil(raw * 1.20) to always round up (and stay
  # conservative).
  defp apply_safety(n) when is_integer(n) and n >= 0 do
    ceil(n * @safety_multiplier)
  end
end
