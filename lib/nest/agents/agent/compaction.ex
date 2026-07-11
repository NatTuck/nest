defmodule Nest.Agents.Agent.Compaction do
  @moduledoc """
  Background compaction tasks. Spawns a Task that runs the
  Compactor on the agent's messages, sends the result back to
  the agent pid via `send/2`.

  Communicates with the GenServer via messages only — never touches
  the Agent state struct directly.

  ## Output contract

  The agent receives one of three outcomes via
  `send/2`:

    * `{:compaction_done, summary_text, continuation}` — the LLM
      returned a summary. The compactor task has already appended
      the `[mode: compact]` suffix (system) and the LLM's
      response (assistant) to `state.chat_state.messages` via
      the canonical append path. `summary_text` is the raw LLM
      text (the regenerator strips `<think>` blocks when
      building the post-compaction user message).
    * `{:compaction_done, :passthrough, continuation}` — the
      conversation was too short to compact. No LLM call, no
      appends, no swap. The handler logs a warning and spawns
      the next chat turn.
    * `{:compaction_failed, reason, continuation}` — the LLM
      call failed or returned empty. The agent enters
      `:compaction_failed` and surfaces a retry.

  The LLM call returns `{:ok, %Nest.LLM.RunResponse{}}` so the
  assistant message recorded on the message list carries
  `usage` / `finish_reason` / `model` exactly as the LLM
  delivered them. Any `<think>` markers in the visible text are
  preserved on the assistant row; the JS history pane renders
  them as collapsed thinking blocks via `splitThinkFromParts`.

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
  alias Nest.Messages.Assistant
  alias Nest.Messages.Part
  alias Nest.Tokens.Compactor

  require Logger

  @type continuation :: Nest.Agents.Agent.ChatTurn.State.continuation()

  # Public API

  @doc """
  Spawns a Task that runs the Compactor on `messages_to_compact`,
  then sends `{:compaction_done, _, continuation}` (or
  `{:compaction_failed, _, continuation}` on error) back to
  `agent_pid`. The continuation is whatever was queued to
  happen after compaction (e.g. the next chat turn).

  On success the compactor task also appends the `[mode: compact]`
  suffix and the LLM's response (as a fresh assistant message) to
  `state.chat_state.messages` via the canonical append path BEFORE
  the regenerator runs. The post-swap `last_compaction_index`
  will be set to the bumped `next_message_index`, so the suffix
  and the assistant response land in `history` from the client's
  perspective.

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
      # The compactor task runs in a different process from
      # the caller. For tests that use `Nest.LLM.MockClient`,
      # the MockClient looks up its queue via
      # `Process.get(:nest_test_agent_pid, self())`. The
      # `start_agent/1` test helper sets the agent's pid as
      # `:nest_test_agent_pid` on the test process, then
      # transfers the test's MockClient queue onto the agent's
      # pid. Threading the agent's pid here lets the
      # compactor task find the same queue the chat turn's
      # HTTP worker does (no per-task `Mimic.stub` needed).
      Process.put(:nest_test_agent_pid, agent_pid)

      result =
        try do
          llm_call =
            build_summarization_llm_call(client_config, rendered_suffix)

          Compactor.compact(messages_to_compact, context_limit, llm_call)
        catch
          kind, reason ->
            Logger.warning("Compaction crashed: #{inspect(kind)} #{inspect(reason)}")

            {:error, {:crash, kind, reason}}
        end

      case result do
        {:ok, summary_text, %RunResponse{} = response} ->
          # Append the suffix and the LLM response as a real
          # assistant message. Both go through the canonical
          # `__append_message__/2` path (so each is stamped,
          # broadcast, and persisted). The agent's state
          # doesn't change here — the append is async via a
          # `GenServer.call`, but the compactor task waits
          # for it before sending `compaction_done`.
          append_compaction_messages(agent_pid, [
            rendered_suffix,
            build_assistant_message(response)
          ])

          send(agent_pid, {:compaction_done, summary_text, continuation})

        {:ok, :passthrough} ->
          # Conversation was too short to compact — no LLM
          # call, no messages to record, no swap. The handler
          # logs a warning and spawns the next chat turn.
          send(agent_pid, {:compaction_done, :passthrough, continuation})

        {:error, reason} ->
          send_failure(agent_pid, reason, continuation)
      end
    end)
  end

  # Best-effort: append the suffix + assistant response to the
  # agent's message list. A GenServer.call failure here would
  # otherwise orphan the messages (the compactor task would still
  # report success, but the agent's state would be missing the
  # new entries). We log loudly and surface a `:compaction_failed`
  # so the agent enters the standard retry path.
  defp append_compaction_messages(agent_pid, messages) do
    case GenServer.call(agent_pid, {:append_compaction_messages, messages}, 5_000) do
      stamped when is_list(stamped) ->
        :ok

      other ->
        Logger.warning(
          "Compaction got unexpected reply appending suffix+assistant: agent=#{inspect(agent_pid)} reply=#{inspect(other)}"
        )

        {:error, :unexpected_reply}
    end
  catch
    :exit, reason ->
      Logger.warning(
        "Compaction failed to append suffix+assistant: agent=#{inspect(agent_pid)} exit=#{inspect(reason)}"
      )

      {:error, {:append_failed, reason}}
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

  # Build an assistant message from the compactor LLM's
  # `RunResponse`. Same shape as a regular chat-turn assistant
  # response for a text-only call (the compactor's LLM request
  # uses `tools: nil, tool_choice: :none`, so the response has
  # no tool calls). The visible text is stored as-is — including
  # any `<think>` markers — because the assistant row is the
  # recorded artifact of the LLM's reply. Stripping happens once,
  # downstream, when the regenerator builds the post-compaction
  # "Summary of earlier conversation:" user message.
  @spec build_assistant_message(RunResponse.t()) :: {:assistant, Assistant.t()}
  def build_assistant_message(%RunResponse{} = response) do
    {:assistant,
     %Assistant{
       index: 0,
       parts: [%Part.Text{text: response.text || ""}],
       usage: response.usage,
       finish_reason: response.stop_reason,
       model: response.model,
       timestamp: DateTime.utc_now(),
       metadata: nil,
       api_logs: [],
       tokens: nil
     }}
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
  # Returns `{:ok, %RunResponse{}}` on success or `{:error, reason}`
  # on transport-level failure. An empty response text surfaces as
  # `:llm_returned_empty` upstream in `Compactor.compact/3`'s
  # `require_summary/1` guard.
  @spec build_summarization_llm_call(ClientConfig.t(), Message.t()) ::
          (... -> {:ok, RunResponse.t()} | {:error, term()})
  def build_summarization_llm_call(client_config, rendered_suffix) do
    fn messages, _remaining_tokens, _optional_guidance ->
      # Send the agent's prior conversation + the suffix
      # unchanged. There is no special input stripping here —
      # the compactor's LLM sees exactly the same conversation
      # a regular chat turn would see. Any `<think>` markers in
      # the agent's prior assistant responses are sent through;
      # the compactor is told (via its system prompt and the
      # `[mode: compact]` suffix) to summarize, and it handles
      # its own thinking the same way the chat turn does.
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
  # `{:ok, %RunResponse{}}` with the streamed response, or
  # `{:error, reason}` if the stream errored out mid-flight.
  defp consume_quietly(stream, compaction_pid) do
    consumer = %StreamConsumer{
      on_text: &forward_text_delta(&1, &2, compaction_pid),
      on_thinking: &forward_thinking_delta(&1, &2, compaction_pid),
      on_signature: fn _sig -> :ok end
    }

    {_acc, response, error, _sent} = StreamConsumer.reduce(stream, consumer)

    cond do
      not is_nil(error) -> {:error, error}
      match?(%RunResponse{}, response) -> {:ok, response}
      true -> {:error, :no_response}
    end
  end

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
