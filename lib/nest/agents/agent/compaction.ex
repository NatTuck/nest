defmodule Nest.Agents.Agent.Compaction do
  @moduledoc """
  Background compaction tasks. Spawns a Task that runs the
  Compactor on the agent's messages, sends the result back to
  the agent pid via `send/2`.

  Communicates with the GenServer via messages only — never touches
  the Agent state struct directly.

  ## Output contract

  The `new_messages` sent back to the agent pid **always starts
  with a `{:system, _}` message**. The agent's compaction handler
  pattern-matches this invariant: it extracts the compactor's
  summary text from position 0 and re-encodes it as a `{:user, _}`
  "Summary of earlier conversation" message at position 1 of the
  regenerated list, with a freshly-rendered base system prompt
  at position 0.

  The contract is structurally guaranteed by `Nest.Tokens.Compactor`:
  the `:too_short` branch returns the input unchanged (the agent's
  state always starts with a system message), and the other
  branches explicitly prepend the original system message. If this
  module ever stops producing a leading `{:system, _}`, the
  handler's pattern match will raise — that is intentional, as a
  malformed compactor output would silently corrupt the agent's
  state.

  ## [mode: compact] convention

  The agent's initial system prompt lists `compact` in its
  `[Available modes]` section (`Nest.Vocations.compact_description/0`).
  That entry is the single source of the summarization contract;
  no trailing `[mode: compact]` paragraph is appended to the
  prompt. The compactor's request APPENDS a per-call suffix system
  message:

      [mode: compact] Summarize the conversation in your
      <N> remaining tokens. <optional_guidance?>

  The agent sees its system prompt (with the canonical guidance
  in the mode list) and the per-call suffix (with the dynamic
  budget hint) and produces a bounded `head_summary`.

  KV cache reuse is automatic on providers that support prefix
  caching (Anthropic prompt caching; OpenAI's prefix-matching
  auto-cache): the compactor's request shares the agent's prior
  prefix up to the suffix, so the compactor reuses everything
  it can while still producing a fresh response.

  ## Continuations

  The continuation tuple is the "what's the outstanding
  content for this chat turn's first iteration?" payload —
  identical to `Nest.Agents.Agent.ChatTurn.State.continuation/0`:

    * `{:user_message, User.t()}` — Trigger 1 (user-turn
      boundary); the user message is appended to the
      post-compaction active list and the new ChatTurn's
      first iter calls the LLM.

    * `{:tool_call, Assistant.t(), non_neg_integer(),
      pos_integer()}` — Trigger 2 (mid-turn preflight failure
      after the LLM emitted tool calls); the carried
      assistant+ToolUse is preserved on the post-compaction
      active list and the new ChatTurn's first iter runs the
      tool calls (iteration count preserved).

    * `{:compact_tool, [Assistant.t(), Tool.t()],
      non_neg_integer(), pos_integer()}` — Trigger 3 (LLM
      called `context.compact`); the carried pair [tool_call,
      synthetic_tool_result] ends up on the post-compaction
      active list and the new ChatTurn's first iter falls
      through to the LLM (iteration count preserved).

  Per-iteration preflight compaction has been removed; the
  BatchSizer handles tool-result sizing instead. See the doc
  for the redesign.
  """

  alias Nest.LLM.ClientConfig
  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer
  alias Nest.Tokens.Compactor

  require Logger

  @type continuation :: Nest.Agents.Agent.ChatTurn.State.continuation()

  # Public API

  @doc """
  Spawns a Task that runs the Compactor on `messages_to_compact`,
  then sends `{:compaction_done, new_messages, continuation}` back
  to `agent_pid`. The continuation is whatever was queued to
  happen after compaction (e.g. the next chat turn).

  `rendered_suffix` is the `{:system, _}` system message the
  caller pre-computed via `Nest.Tokens.Compactor.
  compute_summary_budget/4`. The LLM call appends this message
  to its request — no re-render, no re-measure, so the suffix
  size the budget was sized against matches the suffix on the
  wire.

  The `optional_guidance` (focus arg from the `:compact` tool or
  future `/compact` slash command) and `remaining_tokens` (N
  budget) are embedded into the rendered suffix — passing them
  separately is no longer required.
  """
  @spec spawn(
          pid(),
          ClientConfig.t(),
          pos_integer() | nil,
          [Message.t()],
          continuation(),
          Message.t()
        ) :: Task.t()
  def spawn(
        agent_pid,
        client_config,
        context_limit,
        messages_to_compact,
        continuation,
        rendered_suffix
      ) do
    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      result =
        try do
          llm_call = build_summarization_llm_call(client_config, rendered_suffix)

          Compactor.compact(messages_to_compact, context_limit, llm_call)
        catch
          kind, reason ->
            Logger.warning("Compaction crashed: #{inspect(kind)} #{inspect(reason)}")

            {:error, {:crash, kind, reason}}
        end

      case result do
        {:ok, new_messages} ->
          send(agent_pid, {:compaction_done, new_messages, continuation})

        {:error, reason} ->
          send_failure(agent_pid, reason, continuation)
      end
    end)
  end

  @doc """
  Assigns monotonically-increasing message indices starting at
  `start_index`. Pure utility, exposed for the GenServer's
  `__compaction_completed__/2` to use.
  """
  @spec assign_indices([Message.t()], non_neg_integer()) :: [Message.t()]
  def assign_indices(messages, start_index) do
    {messages, _} =
      Enum.map_reduce(messages, start_index, fn msg, idx ->
        {assign_index(msg, idx), idx + 1}
      end)

    messages
  end

  # Private

  # Single failure path: send `{:compaction_failed, reason, continuation}`
  # to the Agent. The Agent's compaction handler routes by continuation
  # shape and sets `:compaction_failed` status + broadcasts `chat:error`.
  # The previous behavior — sending `{:compaction_done, original_messages, _}`
  # and silently masking failures — was a state-corruption bug.
  defp send_failure(agent_pid, reason, continuation) do
    send(agent_pid, {:compaction_failed, reason, continuation})
  end

  # The LLM call the compactor uses. Wraps the chat client so the
  # summarization LLM request is routed through the same provider
  # the agent is using (KV cache prefix reuse, etc.).
  #
  # The request is the agent's prior conversation + a trailing
  # `[mode: compact]` system message. The agent's own system prompt
  # (with the [mode: compact] paragraph) stays at position 0; the
  # suffix arrives at the END as a fresh system message telling
  # the model what to do this turn.
  #
  # `rendered_suffix` is the precomputed system message from
  # `Nest.Tokens.Compactor.compute_summary_budget/4` — already
  # sized and rendered so the LLM call's input budget matches the
  # budget the compactor's N was computed against.
  #
  # `tools: nil` and `tool_choice: :none` constrain the response to
  # plain text. The compactor doesn't need tool calls for
  # summarization — it just needs the model to emit the bounded
  # summary text.
  #
  # Returns `{:ok, text}` on success or `{:error, reason}` on
  # transport-level failure. An empty `text` is returned as
  # `{:ok, ""}` — the compactor's `require_summary/1` then converts
  # that to `{:error, :llm_returned_empty}` so the failure surfaces
  # to the Agent's compaction handler.
  @spec build_summarization_llm_call(ClientConfig.t(), Message.t()) ::
          (... -> {:ok, String.t()} | {:error, term()})
  def build_summarization_llm_call(client_config, rendered_suffix) do
    fn messages, _remaining_tokens, _optional_guidance ->
      # The wire payload is constant across calls — the compactor
      # contract accepts the trailing args for symmetry, but the
      # `rendered_suffix` is already baked in.
      request = %Nest.LLM.RunRequest{
        messages: messages ++ [rendered_suffix],
        tools: nil,
        tool_choice: :none,
        model: client_config.model,
        stream: true,
        metadata: %{}
      }

      opts = [
        base_url: client_config.base_url,
        api_key: client_config.api_key,
        receive_timeout: client_config.receive_timeout
      ]

      case client_config.client.run(request, opts) do
        {:ok, stream} -> consume_quietly(stream, self())
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Consume a streaming response without broadcasting. Returns
  # `{:ok, text}` with the streamed response text, or
  # `{:error, reason}` if the stream errored out mid-flight.
  # An empty string is returned as `{:ok, ""}` — the compactor
  # detects the empty summary and surfaces the failure.
  defp consume_quietly(stream, compaction_pid) do
    consumer = %StreamConsumer{
      on_text: &forward_text_delta(&1, &2, compaction_pid),
      on_thinking: &forward_thinking_delta(&1, &2, compaction_pid),
      on_signature: fn _sig -> :ok end
    }

    {acc, response, error, _sent} = StreamConsumer.reduce(stream, consumer)

    cond do
      not is_nil(error) -> {:error, error}
      match?(%RunResponse{}, response) -> {:ok, streamed_text(response, acc)}
      true -> {:error, :no_response}
    end
  end

  # Read the response text preferring the wire-level
  # `RunResponse.text` (populated by clients that build a
  # complete response on `:done`) and falling back to the
  # accumulator's streamed text IO-list (the canonical source
  # for OpenAI-style streams where the wire `RunResponse.text`
  # is `nil` because the client expects the caller to merge via
  # `Runner.normalize_response/2`).
  #
  # Exposed as `@doc false` for regression testing the production
  # `:llm_returned_empty` misdiagnosis — without the accumulator
  # fallback, every successful summary (one where the LLM
  # streamed thousands of `text_chars` but the wire `:done`
  # response had `text: nil`) used to surface as `:llm_returned_empty`.
  @doc false
  @spec streamed_text(RunResponse.t() | nil, Client.accumulator()) :: String.t()
  def streamed_text(%RunResponse{text: text}, _acc) when is_binary(text), do: text
  def streamed_text(%RunResponse{}, acc), do: io_list_to_binary(acc.text)
  def streamed_text(nil, acc), do: io_list_to_binary(acc.text)

  # `Client.accumulate/2` prepends to `acc.text` (a reverse-order
  # IO list). `IO.iodata_to_binary/1` walks it but expects
  # forward order, so reverse first.
  defp io_list_to_binary([]), do: ""
  defp io_list_to_binary(iolist), do: iolist |> Enum.reverse() |> IO.iodata_to_binary()

  defp forward_text_delta(text, sent, compaction_pid) do
    send(compaction_pid, {:delta_received, text, :text})
    sent
  end

  defp forward_thinking_delta(text, sent, compaction_pid) do
    send(compaction_pid, {:delta_received, text, :thinking})
    sent
  end

  defp assign_index({role, %_{} = struct}, idx) do
    {role, %{struct | index: idx}}
  end

  defp assign_index(other, _idx), do: other
end
