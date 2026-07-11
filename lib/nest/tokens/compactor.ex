defmodule Nest.Tokens.Compactor do
  @moduledoc """
  Single-pass compaction of an LLM message history.

  Called when the pre-flight check decides the next LLM call
  won't fit. The compactor produces a new, smaller history:

    1. Preserves the system message at position 0.
    2. Replaces everything after the system with a single
       prose summary produced by the LLM (the "head summary").

  Recent-tail preservation (the previous design kept the last
  user message + tool response sequence verbatim) is gone.
  At small contexts a single `shell_cmd` result can
  consume half the window on its own — preserving the recent
  slice verbatim alongside the head summary can blow past
  25% of context in the post-compaction state. The new
  design trusts the LLM's summary to capture the local tool
  flow instead.

  ## Algorithm

      system = messages[0]
      {summary, response} = llm_call(messages, remaining_tokens, optional_guidance)

  The compactor returns the LLM's summary text and its raw
  `RunResponse`. The caller (`Nest.Agents.Agent.Compaction`)
  records the response as an assistant message on the agent's
  message list (via the canonical append path, same as a regular
  chat-turn assistant response) and uses the summary text to
  derive a "Summary of earlier conversation" user message after
  the swap. The compactor does not wrap, rename, or otherwise
  reshape the response.

  The LLM call is set up by the caller. It sends a request whose
  messages END with a `[mode: compact]` system suffix carrying
  the dynamic budget hint:

      [mode: compact] Summarize the conversation in your
      <N> remaining tokens. <optional_guidance?>

  The agent's initial system prompt carries a `[mode: compact]`
  paragraph explaining the summarization contract. Together,
  the agent's known guidelines + the per-call budget produce a
  bounded summary.

  ## Why single-pass

  The old two-pass design (head summary, then tail summary)
  turned every compaction into a chat-vs-summary chat. The
  post-compaction recent-slice ceiling on Pass 1 also
  diverged from the budget hint at large contexts: we'd tell
  the LLM it had 140k tokens of room while refusing anything
  over 50k. Now there's exactly one LLM call per compaction
  and its budget is the LLM's full response headroom (`reserve`).
  Refusal happens upstream (in `compute_summary_budget/4` when
  the reserve can't accommodate the system + request overhead).

  ## KV-cache friendliness

  Pass 1's input is the agent's full prior conversation plus
  the trailing `[mode: compact]` suffix. The post-compaction
  LLM call starts with the same prefix plus the new summary.
  LLM providers that support prompt caching can hit the cache
  for the `[system, …, last_user_prefix, …]` portion across
  the compactor call and the next agent call.
  """

  alias Nest.LLM.RunResponse
  alias Nest.Messages.Message
  alias Nest.Messages.Part
  alias Nest.Messages.System, as: MsgSystem
  alias Nest.Messages.ThinkTags
  alias Nest.Scripts.CompactionProbeSupport
  alias Nest.Tokens.Estimator
  alias Nest.Tokens.Reserve

  # Worst-case delta between rendering the suffix with `N=1` and
  # with the actual N (e.g., 200_000). One digit difference is 1
  # char, ~1 token after the estimator's safety multiplier. We
  # add 10 tokens of headroom to absorb up to a 5-digit N plus a
  # safety margin. Real contexts won't exceed 7-digit Ns for the
  # foreseeable future, so 10 is conservative.
  @digit_count_buffer 10

  @type llm_call :: ([Message.t()], non_neg_integer(), String.t() | nil ->
                       {:ok, RunResponse.t()} | {:error, term()})

  @type compact_result ::
          {:ok, String.t(), RunResponse.t()}
          | {:ok, :passthrough}
          | {:error, term()}

  @type summary_budget ::
          {:ok, non_neg_integer(), Message.t()}
          | {:error, :reserve_exhausted}

  @doc """
  Compute the compactor's `<N>` budget hint and the rendered
  suffix message, self-consistently.

  The LLM call's response is what fits in `reserve` once the
  system message and the compaction request are accounted for.
  The rendered suffix message is built to size so the LLM can
  consume it directly — no re-measurement at call time.

  ## Parameters

    * `context_limit` — the model's context window in tokens.
    * `system_msg` — the agent's `{:system, _}` message
      (index 0 of the chat state). The caller must extract
      this and pass it in; it's not derived here.
    * `current_messages` — the full chat-state message list
      (used to verify the compactor's call will fit).
    * `optional_guidance` — `:compact` tool's `focus` arg, or
      `nil`/empty for the typical user-turn-boundary path.
      When non-nil/non-empty, it's appended to the suffix.

  ## Returns

    * `{:ok, n, rendered_suffix}` — n is the LLM's budget for
      the summary text (a positive integer). The rendered
      suffix is a `{:system, _}` message that the caller's
      LLM-call builder uses directly.
    * `{:error, :reserve_exhausted}` — `reserve` is too small
      to hold the system + suffix (e.g., a 32k-context model
      where the system's already-cost + suffix-cost > 8192).
      The caller surfaces this as a context overflow; the
      user must change model or clear history.

  ## How N is computed (single-pass + flat buffer)

      suffix_size = estimate(suffix_with_N=1) + @digit_count_buffer
      n_headroom  = reserve - system_size - suffix_size
      n_call_fits = limit - current_messages - suffix_size
      n           = min(n_headroom, n_call_fits) clamped to ≥ 0

  The `@digit_count_buffer` of 10 tokens absorbs the variance
  between rendering the suffix with `N=1` (a 1-char number) and
  the actual N (up to a 6-char number for billion-token contexts).
  See `lib/nest/tokens/reserve.ex` for why `reserve` is what it is.
  """
  @spec compute_summary_budget(
          pos_integer(),
          Message.t(),
          [Message.t()],
          String.t() | nil
        ) :: summary_budget()
  def compute_summary_budget(context_limit, system_msg, current_messages, optional_guidance)
      when is_integer(context_limit) and context_limit > 0 and is_list(current_messages) do
    reserve = Reserve.response_budget(context_limit)
    system_size = Estimator.estimate_message(system_msg)

    placeholder = render_suffix(1, optional_guidance)
    suffix_base = Estimator.estimate_message(placeholder)
    suffix_size = suffix_base + @digit_count_buffer

    n_headroom = max(0, reserve - system_size - suffix_size)

    n_call_fits =
      max(0, context_limit - Estimator.estimate_messages(current_messages) - suffix_size)

    n = min(n_headroom, n_call_fits)

    case n do
      0 -> {:error, :reserve_exhausted}
      _ -> {:ok, n, render_suffix(n, optional_guidance)}
    end
  end

  @doc """
  Compact the given `messages` list by asking the LLM to
  summarize. See the moduledoc for the full algorithm and KV-cache
  rationale.

  ## Parameters

    * `messages` — the current message history (tagged tuples).
    * `context_limit` — the model's context window in tokens.
    * `llm_call` — callback `(messages, remaining_tokens,
      optional_guidance) -> {:ok, run_response} | {:error, reason}`.
      The caller builds the actual LLM request, appending the
      `[mode: compact]` suffix to the agent's prior conversation.
      The callback returns the wire-level `RunResponse`; the
      compactor extracts `.text` for the empty-summary guard and
      forwards both to the caller.

  ## Return values

    * `{:ok, summary_text, run_response}` — success. The compactor
      returns the response's visible text and the full
      `RunResponse` so the caller can record the assistant
      message as-received and build the post-compaction summary
      user message from the same text.
    * `{:ok, :passthrough}` — the input was too short to compact
      (`:too_short`: empty / system-only / system + single user /
      no head to summarize). No LLM call was made; the caller
      skips the swap and just spawns the next chat turn.
    * `{:error, :llm_returned_empty}` — the LLM call returned
      an empty string for the summary. The compactor does not
      synthesize a placeholder summary; it surfaces the failure.
    * `{:error, reason}` — any other LLM-call transport or runtime
      error.
  """
  @spec compact([Message.t()], pos_integer(), llm_call()) :: compact_result()
  def compact(messages, context_limit, llm_call_fn)
      when is_list(messages) and is_integer(context_limit) and
             context_limit > 0 and is_function(llm_call_fn, 3) do
    case split_messages(messages) do
      :too_short ->
        {:ok, :passthrough}

      {:ok, _system} ->
        with {:ok, response} <- llm_call_fn.(messages, 0, nil),
             %RunResponse{text: text} = response,
             :ok <- require_summary(text),
             :ok <- require_non_empty_summary(text) do
          {:ok, text || "", response}
        end
    end
  end

  # No-op if the history is too short to need compaction: empty
  # list, only a system message, system + a single user (no head
  # to summarize), or any shape that doesn't lead with a system
  # message. Asking the LLM to summarize the bare system prompt
  # produces a meaningless call, so signal :passthrough and let
  # the caller skip the swap.
  defp split_messages([]), do: :too_short
  defp split_messages([_only]), do: :too_short
  defp split_messages([{:system, _}, {:user, _}]), do: :too_short

  defp split_messages([{:system, _} = system | _rest]) do
    {:ok, system}
  end

  defp split_messages(_other), do: :too_short

  defp require_summary(""), do: {:error, :llm_returned_empty}
  defp require_summary(_text), do: :ok

  # Stripped-and-trimmed guard: rejects LLM responses whose
  # visible content is empty or whitespace-only. Covers:
  #   * LLM emitted only `<think>...</think>` blocks (no
  #     visible summary) — common when the model's response
  #     gets truncated mid-thinking by token budget.
  #   * Whitespace-only responses (`"   "`, `"\n\n"`).
  #
  # Without this, `ThinkTags.strip/1` (applied later by the
  # regenerator when building the summary_user) collapses
  # those responses to `""` and the user sees the
  # `Summary of earlier conversation:` header followed by
  # nothing. Failing here lets the agent surface a retryable
  # `:llm_returned_empty` (same shape as the bare-empty case
  # — both mean "the LLM produced no visible summary").
  defp require_non_empty_summary(text) do
    if String.trim(ThinkTags.strip(text)) == "" do
      {:error, :llm_returned_empty}
    else
      :ok
    end
  end

  # Render the compaction request as a `{:system, _}` tuple the
  # compactor's LLM call appends to its request. Wraps
  # `CompactionProbeSupport.compaction_suffix/2` in a System
  # struct. The `index` field is `nil` — the suffix is an LLM-call
  # input element, not a persisted message. Receivers that need a
  # real index (e.g., for sequence IDs) reassign later.
  defp render_suffix(n, guidance)
       when is_binary(guidance) and guidance != "" do
    text = CompactionProbeSupport.compaction_suffix(n, guidance)
    wrap_request_suffix(text)
  end

  defp render_suffix(n, guidance) when guidance in [nil, ""] do
    text = CompactionProbeSupport.compaction_suffix(n, "")
    wrap_request_suffix(text)
  end

  defp wrap_request_suffix(text) do
    {:system,
     %MsgSystem{
       index: nil,
       parts: [%Part.Text{text: text}],
       timestamp: DateTime.utc_now(),
       api_logs: []
     }}
  end
end
