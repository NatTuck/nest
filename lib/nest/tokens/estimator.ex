defmodule Nest.Tokens.Estimator do
  @moduledoc """
  Token estimation for the LLM context budget.

  Counts tokens for strings, message lists, and tool results using
  the `tiktoken` library's `cl100k_base` encoding (the encoding used
  by GPT-3.5/GPT-4 and a reasonable proxy for Anthropic Claude's
  tokenizer — typically within 5-10% for mixed text).

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
  alias Nest.Messages.System
  alias Nest.Messages.Tool
  alias Nest.Messages.ToolCall
  alias Nest.Messages.ToolResult
  alias Nest.Messages.User

  # 20% safety multiplier on top of the real cl100k_base count.
  # Applied to every public function in this module.
  @safety_multiplier 1.20

  # Per-message wire-format overhead. The role tag ("system",
  # "user", "assistant", "tool"), JSON delimiters, message
  # wrapper, etc. add a handful of tokens that the raw count
  # misses. We add a flat 10 tokens per message to absorb this.
  @per_message_overhead 10

  # "gpt-4" is the canonical model name that maps to cl100k_base
  # inside the tiktoken package. We don't have a specific model
  # in mind — the encoding is what we want.
  @tiktoken_model "gpt-4"

  @doc """
  Returns the **real** token count for a string using cl100k_base.
  No safety multiplier.

  Useful for telemetry, display, and tests that want to compare
  against a known baseline.
  """
  @spec raw_count(String.t()) :: pos_integer()
  def raw_count(text) when is_binary(text) do
    case Tiktoken.count_tokens(@tiktoken_model, text) do
      {:ok, n} -> n
      {:error, _} -> fallback_estimate(text)
    end
  end

  def raw_count(_), do: 0

  @doc """
  Returns a **conservative** token count for a string.

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
  def estimate_message({:system, %System{content: content}}),
    do: estimate(content || "")

  def estimate_message({:user, %User{content: content}}),
    do: estimate(content || "")

  def estimate_message({:assistant, %Assistant{} = msg}) do
    text = (msg.content || "") <> (msg.thinking || "")
    text_size = estimate(text)
    thinking_sig_size = if(msg.thinking_signature, do: estimate(msg.thinking_signature), else: 0)
    tool_calls_size = estimate_tool_calls(msg.tool_calls)
    text_size + thinking_sig_size + tool_calls_size
  end

  def estimate_message({:tool, %Tool{tool_results: results}}) do
    estimate_tool_results(results || [])
  end

  def estimate_message(_), do: @per_message_overhead

  @doc """
  Returns a conservative token count for a list of tool results.
  """
  @spec estimate_tool_results([ToolResult.t()] | nil) :: pos_integer()
  def estimate_tool_results(nil), do: 0
  def estimate_tool_results([]), do: 0

  def estimate_tool_results(results) when is_list(results) do
    Enum.reduce(results, 0, fn result, acc ->
      acc + estimate_tool_result(result)
    end)
  end

  def estimate_tool_results(_), do: 0

  @doc """
  Returns a conservative token count for a single tool result.
  """
  @spec estimate_tool_result(ToolResult.t()) :: pos_integer()
  def estimate_tool_result(%ToolResult{content: content} = result) do
    content_size = estimate(content || "")
    args_size = estimate_json(result.arguments)
    content_size + args_size
  end

  def estimate_tool_result(_), do: @per_message_overhead

  @doc """
  Returns a conservative token count for a list of tool calls
  (assistant-side; not the results).
  """
  @spec estimate_tool_calls([ToolCall.t()] | nil) :: pos_integer()
  def estimate_tool_calls(nil), do: 0
  def estimate_tool_calls([]), do: 0

  def estimate_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.reduce(tool_calls, 0, fn call, acc ->
      acc + estimate_tool_call(call)
    end)
  end

  def estimate_tool_calls(_), do: 0

  defp estimate_tool_call(%ToolCall{name: name, arguments: args}) do
    name_size = estimate(name || "")
    args_size = estimate_json(args)
    # Per-tool-call wire format overhead (function wrapper, id, etc.)
    name_size + args_size + 20
  end

  defp estimate_tool_call(_), do: @per_message_overhead

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

  # Fallback when tiktoken errors out: chars / 4, which is a
  # reasonable worst-case for English text. This should never
  # happen in practice (the NIF is always loaded) but keeps us
  # safe if the dep fails to compile in some environment.
  defp fallback_estimate(text) when is_binary(text) do
    div(String.length(text) + 3, 4)
  end
end
