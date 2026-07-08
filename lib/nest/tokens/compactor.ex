defmodule Nest.Tokens.Compactor do
  @moduledoc """
  Two-pass compaction of an LLM message history.

  Called when the pre-flight check decides the next LLM call won't
  fit. The compactor produces a new, smaller history that:
    1. Preserves the system message
    2. Replaces everything before the last user message with a
       prose summary ("head summary")
    3. Either keeps the last user message and the post-user
       response sequence verbatim, or summarizes the response
       sequence as well ("tail summary") if even the recent slice
       is too large

  ## Algorithm

      system     = messages[0]                      # always system
      last_user  = last {:user, _} in messages
      responses  = messages after last_user          # assistant/tool pairs
      head       = messages between system and last_user

      # Pass 1: head summary (system + head are the cache prefix)
      head_summary = llm_call([system | head])

      # Size check: does the recent slice fit in 25% of context?
      head_tokens  = estimate(head_summary)
      tail_tokens  = estimate(last_user) + estimate(responses)
      recent_total = head_tokens + tail_tokens

      if recent_total <= 0.25 * context_limit:
        new_messages = [system, head_summary, last_user] ++ responses
      else:
        # Pass 2: tail summary (shares [system, head_summary] prefix)
        tail_input   = [system, head_summary, last_user] ++ responses
        tail_summary = llm_call(tail_input)
        new_messages = [system, head_summary, last_user, tail_summary]

  ## KV-cache friendliness

  Pass 1's input is `[system | head]`. Pass 2's input starts with
  the same `[system | head_summary]` prefix plus the recent
  messages. The post-compaction LLM call also starts with the same
  prefix. LLM providers that support prompt caching can hit the
  cache for the `[system, head_summary]` prefix across all three
  calls.
  """

  alias Nest.Messages.Message
  alias Nest.Tokens.Estimator

  @recent_threshold 0.25

  @type llm_call :: ([Message.t()] -> {:ok, String.t()} | {:error, term()})

  @type compact_result :: {:ok, [Message.t()]} | {:error, term()}

  @doc """
  Compact the given `messages` list.

  ## Parameters

    * `messages` — the current message history (tagged tuples)
    * `context_limit` — the model's context window in tokens, used
      for the 25% threshold
    * `llm_call` — callback that takes the messages to summarize
      and returns `{:ok, summary_text}` on success or
      `{:error, reason}` on transport / parse failure. The caller
      is responsible for building the actual LLM request (including
      the summarization system prompt).

  ## Return values

    * `{:ok, messages}` — success. The `:too_short` branch (empty /
      system-only / no-user) returns the input unchanged under the
      same `{:ok, messages}` shape; callers that care can detect it
      by comparing lengths.
    * `{:error, :llm_returned_empty}` — the LLM call returned an
      empty string for either the head or tail summary. The compactor
      does not synthesize a placeholder summary; it surfaces the
      failure to the caller.
    * `{:error, reason}` — transport-level error from the LLM call
      (timeout, network, etc.) propagated through the callback.

  ## Output contract

  The returned list **always starts with a `{:system, _}` message**.
  This invariant is structurally guaranteed:

  - The `:too_short` branch returns the input unchanged. The caller
    (the agent's `state.chat_state.messages`) always starts with a
    system message, so the output also starts with one.
  - The other branches explicitly prepend the original system message
    (extracted from `List.first(head)` where `head` is everything
    before the last user message).

  Summary messages (the head and tail summaries produced by the
  two-pass algorithm) are also tagged as `{:system, _}` via
  `wrap_summary/2`. This is the convention the agent's compaction
  handler relies on: position 0 of the compactor's output is always
  a system message, and the handler can re-encode it as a user
  "Summary of earlier conversation" message without ambiguity.
  """
  @spec compact([Message.t()], pos_integer(), llm_call()) :: compact_result()
  def compact(messages, context_limit, llm_call_fn)
      when is_list(messages) and is_integer(context_limit) and
             context_limit > 0 and is_function(llm_call_fn, 1) do
    case split_messages(messages) do
      :too_short ->
        {:ok, messages}

      {:ok, system, head, last_user, responses} ->
        run_two_pass(system, head, last_user, responses, context_limit, llm_call_fn)
    end
  end

  # No-op if the history is too short to need compaction: empty
  # list, or only a system message, or only a system + single
  # user (no head to summarize, no responses yet).
  defp split_messages([]), do: :too_short
  defp split_messages([_only]), do: :too_short

  defp split_messages(messages) do
    # Find the LAST user message. We anchor on the most recent
    # user turn; everything between system and that turn is the
    # "head" (history to summarize), and everything after is the
    # "responses" (the most recent turn's tool flow).
    last_user_idx = find_last_user_index(messages)

    case last_user_idx do
      nil ->
        :too_short

      0 ->
        # First message is a user; no system message present.
        # This shouldn't happen in normal flow.
        :too_short

      user_idx ->
        {head, [last_user | responses]} = Enum.split(messages, user_idx)
        system = List.first(head)
        # The head we want to summarize is everything BEFORE the
        # last user EXCEPT the system message.
        head_to_summarize =
          case head do
            [] -> []
            [_system | rest] -> rest
            _ -> head
          end

        if Enum.empty?(head_to_summarize) do
          # Nothing between the system prompt and the last user
          # message — the conversation has no history to summarize.
          # Asking the LLM to summarize the bare system prompt
          # produces a meaningless call (empty result or a
          # re-statement of the system prompt), so return the
          # input unchanged. Callers that detect this case should
          # refuse the user's request rather than trigger
          # compaction.
          :too_short
        else
          {:ok, system, head_to_summarize, last_user, responses}
        end
    end
  end

  defp find_last_user_index([]), do: nil

  defp find_last_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, idx} ->
      if match?({:user, _}, msg), do: idx
    end)
  end

  defp run_two_pass(system, head, last_user, responses, context_limit, llm_call_fn) do
    # Pass 1: head summary. The system prompt is prepended to the
    # input so the LLM knows the conversation context.
    head_input = prepend_system(system, head)

    with {:ok, head_summary} <- llm_call_fn.(head_input),
         :ok <- require_summary(head_summary) do
      summarize_or_compact(
        system,
        head_summary,
        last_user,
        responses,
        context_limit,
        llm_call_fn
      )
    end
  end

  # Decide between single-pass (recent slice fits in 25% of context)
  # and two-pass (tail summary needed). Extracted from
  # `run_two_pass/6` to keep that function under the ABC / nesting
  # limits.
  defp summarize_or_compact(
         system,
         head_summary,
         last_user,
         responses,
         context_limit,
         llm_call_fn
       ) do
    recent_total = recent_slice_tokens(head_summary, last_user, responses)

    if recent_total <= round(context_limit * @recent_threshold) do
      {:ok, [system, wrap_summary(head_summary), last_user] ++ responses}
    else
      tail_summarize(system, head_summary, last_user, responses, llm_call_fn)
    end
  end

  defp recent_slice_tokens(head_summary, last_user, responses) do
    head_tokens = Estimator.estimate(head_summary)
    last_user_tokens = Estimator.estimate_message(last_user)
    responses_tokens = Estimator.estimate_messages(responses)
    head_tokens + last_user_tokens + responses_tokens
  end

  # Pass 2: tail summary. Shares [system, head_summary] prefix
  # with pass 1's output.
  defp tail_summarize(system, head_summary, last_user, responses, llm_call_fn) do
    tail_input = prepend_system(system, [wrap_summary(head_summary), last_user] ++ responses)

    with {:ok, tail_summary} <- llm_call_fn.(tail_input),
         :ok <- require_summary(tail_summary) do
      {:ok, [system, wrap_summary(head_summary), last_user, wrap_summary(tail_summary)]}
    end
  end

  defp require_summary(""), do: {:error, :llm_returned_empty}
  defp require_summary(_text), do: :ok

  # Prepends the system message to the input. If the system
  # message is nil (no system at all), returns the input as-is.
  defp prepend_system(nil, messages), do: messages
  defp prepend_system(system, []), do: [system]
  defp prepend_system(system, messages), do: [system | messages]

  defp wrap_summary(text) do
    # Returns the raw LLM summary text wrapped as a system message.
    # No prefix or placeholder is added; the agent's compaction
    # handler is responsible for prefixing when it re-encodes the
    # summary as a user message.
    #
    # Contract: returns a {:system, %System{}} tuple. The handler
    # pattern-matches the compactor's output's position 0 as
    # {:system, _} and extracts the summary text from there.
    # Empty text never reaches this function: require_summary/1
    # short-circuits with {:error, :llm_returned_empty} before
    # wrap_summary/1 is called.
    {:system,
     %Nest.Messages.System{
       # will be re-assigned by the caller
       index: 0,
       parts: [%Nest.Messages.Part.Text{text: text}],
       timestamp: DateTime.utc_now(),
       api_logs: []
     }}
  end
end
