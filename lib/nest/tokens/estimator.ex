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

  # cl100k_base count, with a heuristic fallback on any tokenizer
  # failure. `Nest.Tokens.Tokenizer.count/1` reads a pre-loaded
  # tokenizer from `:persistent_term`; the only expected failure is
  # invalid UTF-8, which the caller already filters with
  # `String.valid?/1`. The rescue stays as a safety net.
  defp count_tokens(text) do
    Tokenizer.count(text)
  rescue
    _ -> char_estimate(text)
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
