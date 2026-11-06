defmodule Nest.Agents.Agent.ResultPolicy do
  @moduledoc """
  The one place a result's inline size is decided.

  ## The formula

      budget    = context_limit - compaction reserve - size(messages) - already admitted
      requested = the model's `max_result_tokens`, else `default_limit/1`
      inline    = min(requested, budget)

      size(content) <= inline -> inline whole
      otherwise               -> `on_over/1`

  There is no share of the window here: `requested` is what the model asked for
  (or the tool's default), and the only ceiling on it is the budget actually
  left. A model that asks for more than the budget gets the budget; a model that
  asks for nothing gets the default. See `notes/no-truncation-or-overflow.md`.

  ## `on_over/1`

    * `:file` — the content is written to the agent's scratch dir and inlined as
      a pointer + short preview (`Nest.Agents.Agent.BatchSizer.Overflow`). Every
      tool whose output exists nowhere else, and every message.
    * `:refuse` — a size-hint error instead, for content that is already at an
      address the model named: `file-read` (its path). A second copy would be
      redundant, and the model can narrow the read. It is `file-read`'s policy
      **alone** (`on_over/1`), and the one `{:refuse, _}` arm left in the tree is
      `BatchSizer.admit_text/5`; the other result paths (`BatchPlan`,
      `SubAgentResults`, `Inbox.Render`) all file, so their `case` has no
      `:refuse` arm and would crash rather than invent a refusal.

  `file-read` also carries a larger default: a quarter of all reads exceed the
  8k floor, and a refusal costs a round trip where a substitution costs a file.
  """

  alias Nest.Agents.Agent.BatchSizer.Overflow
  alias Nest.Messages.ToolCall
  alias Nest.Tokens.Budget
  alias Nest.Tokens.Estimator

  @default_limit 8_000

  # The per-tool exceptions. Only `file-read` differs, and only because it
  # refuses rather than substitutes.
  @default_limits %{"file-read" => 32_000}

  @type decision :: :inline | :file | :refuse

  @doc "The inline limit a tool gets when the model asks for nothing."
  @spec default_limit(String.t()) :: pos_integer()
  def default_limit(name), do: Map.get(@default_limits, name, @default_limit)

  @doc "How a result over its limit is handled."
  @spec on_over(String.t()) :: :file | :refuse
  def on_over("file-read"), do: :refuse
  def on_over(_name), do: :file

  @doc """
  The size the model asked for, or the tool's default when it asked for nothing
  (or for something that is not a positive integer).
  """
  @spec requested(ToolCall.t()) :: pos_integer()
  def requested(%ToolCall{arguments: args, name: name}) when is_map(args) do
    case Map.get(args, "max_result_tokens") do
      n when is_integer(n) and n > 0 -> n
      _ -> default_limit(name)
    end
  end

  def requested(%ToolCall{name: name}), do: default_limit(name)

  @doc """
  The inline limit for `tool_call` given the `budget` left: `min(requested,
  budget)`.
  """
  @spec limit(ToolCall.t(), non_neg_integer()) :: non_neg_integer()
  def limit(%ToolCall{} = tc, budget) when is_integer(budget) and budget >= 0,
    do: min(requested(tc), budget)

  @doc """
  The decision for `content` against `limit`, with the size it was made on.

  The size comes back with the decision so a caller never estimates the same
  content twice: tokenizing a large result is the expensive part of this path.

  A result no larger than the substitute that would replace it is kept inline
  even over its limit. Filing it would make the request *bigger*, so it is not
  a substitution — and it keeps short diagnostics (a preflight refusal, a tool's
  error line) visible when the window is already spent, which is exactly when
  the model needs to read them.
  """
  @spec admit(binary(), non_neg_integer(), :file | :refuse) :: {decision(), non_neg_integer()}
  def admit(content, limit, on_over) when is_binary(content) do
    size = Estimator.estimate(content)

    cond do
      size <= limit -> {:inline, size}
      size <= Overflow.substitute_size() -> {:inline, size}
      true -> {on_over, size}
    end
  end

  @doc """
  The content budget left in a context: `L - C - size(messages)`, floored at 0.

  `{:ok, budget}` for a positive context limit with budget left; `:none` when
  there is no usable window at all (no positive limit, or one already spent).
  """
  @spec window(map()) :: {:ok, non_neg_integer()} | :none
  def window(%{context_limit: limit} = ctx) when is_integer(limit) and limit > 0 do
    case Budget.remaining(Map.get(ctx, :messages) || [], limit) do
      n when n > 0 -> {:ok, n}
      _ -> :none
    end
  end

  def window(_ctx), do: :none

  @doc """
  The clear error for content that could not be offloaded.

  A failed write is its own error, never a quiet inline fallback: the send gate
  is a never-happen tripwire, not a place to absorb an oversized result.
  """
  @spec offload_failure(non_neg_integer()) :: String.t()
  def offload_failure(size) do
    "Result of ~#{size} tokens could not be included inline and could not be written " <>
      "to a scratch file. The content is unavailable; re-run the call if you still need it."
  end

  @doc """
  The size-hint error for a `:refuse` policy.

  `file-read` is the only tool that refuses (`on_over/1`), so this is its
  wording: it is the refusal the model meets routinely, and it names the knob
  that would have let the read through. The head matches the tool's name so a
  tool that starts refusing fails here — loudly, in this function — rather than
  borrowing a sentence written about a file.
  """
  @spec refusal(non_neg_integer(), non_neg_integer(), String.t()) :: String.t()
  def refusal(size, limit, "file-read") do
    "File is #{size} tokens which exceeds your requested limit of #{limit}."
  end

  @doc """
  A short label for a tool's result, used by the pointer and the refusal.

  The tool's **name**, deliberately, and not its arguments: a label that spelled
  the call (`Output of shell-wait job-7`) repeated what the preceding
  `tool_use` part already carries, and it grew without bound with the argument
  it quoted. The call itself is one part earlier in the transcript; this names
  which tool produced the output and stops there.
  """
  @spec label(String.t()) :: String.t()
  def label(name), do: "Output of #{name}"
end
