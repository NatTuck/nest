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

  @type llm_call :: ([Message.t()] -> String.t())

  @doc """
  Compact the given `messages` list.

  ## Parameters

    * `messages` — the current message history (tagged tuples)
    * `context_limit` — the model's context window in tokens, used
      for the 25% threshold
    * `llm_call` — callback that takes the messages to summarize
      and returns the summary text. The caller is responsible for
      building the actual LLM request (including the summarization
      system prompt).

  Returns the new message list. If the history is already empty
  or has only a system message, returns it unchanged.
  """
  @spec compact([Message.t()], pos_integer(), llm_call()) :: [Message.t()]
  def compact(messages, context_limit, llm_call_fn)
      when is_list(messages) and is_integer(context_limit) and
             context_limit > 0 and is_function(llm_call_fn, 1) do
    case split_messages(messages) do
      :too_short ->
        messages

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

        {:ok, system, head_to_summarize, last_user, responses}
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
    head_summary = llm_call_fn.(head_input)

    # Size check: do the recent slice + head summary fit in
    # 25% of the context?
    head_tokens = Estimator.estimate(head_summary || "")
    last_user_tokens = Estimator.estimate_message(last_user)
    responses_tokens = Estimator.estimate_messages(responses)
    recent_total = head_tokens + last_user_tokens + responses_tokens

    recent_threshold = round(context_limit * @recent_threshold)

    if recent_total <= recent_threshold do
      [system, wrap_summary(head_summary, :head), last_user] ++ responses
    else
      # Pass 2: tail summary. Shares [system, head_summary] prefix
      # with pass 1's output.
      tail_input =
        prepend_system(system, [wrap_summary(head_summary, :head), last_user] ++ responses)

      tail_summary = llm_call_fn.(tail_input)
      [system, wrap_summary(head_summary, :head), last_user, wrap_summary(tail_summary, :tail)]
    end
  end

  # Prepends the system message to the input. If the system
  # message is nil (no system at all), returns the input as-is.
  defp prepend_system(nil, messages), do: messages
  defp prepend_system(system, []), do: [system]
  defp prepend_system(system, messages), do: [system | messages]

  # Wraps the raw summary text from the LLM in a tagged tuple
  # matching the message variants. The summary lives as a
  # "system" message in the new history (since it's not from
  # the user or a real assistant turn).
  defp wrap_summary(text, kind) do
    # Empty summaries are still emitted as a system message so
    # the message indices remain contiguous. The caller may later
    # elide them in the UI.
    prefix =
      case kind do
        :head -> "[Summary of earlier conversation]"
        :tail -> "[Summary of recent work]"
      end

    content =
      case String.trim(text || "") do
        "" -> prefix
        non_empty -> prefix <> ":\n\n" <> non_empty
      end

    {:system,
     %Nest.Messages.System{
       # will be re-assigned by the caller
       index: 0,
       content: content,
       timestamp: DateTime.utc_now(),
       api_logs: []
     }}
  end
end
