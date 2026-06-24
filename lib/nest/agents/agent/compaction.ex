defmodule Nest.Agents.Agent.Compaction do
  @moduledoc """
  Background compaction tasks. Spawns a Task that runs the
  two-pass Compactor on the agent's messages, sends the result
  back to the agent pid via `send/2`.

  Communicates with the GenServer via messages only — never touches
  the Agent state struct directly.

  ## Continuations

  The continuation tuple describes what should happen after
  compaction completes. Three shapes are supported:
    * `{:chat_continuation, {content}}` — the original chat task
      wants to proceed to the next LLM call.
    * `{:preflight_continuation, task_pid}` — the pre-flight check
      asked for compaction and is waiting for the result.
    * `{:task_compaction_continuation, task_pid}` — the `context`
      tool's compact action asked for compaction.
  """

  alias Nest.LLM.ClientConfig
  alias Nest.LLM.RunRequest
  alias Nest.LLM.RunResponse
  alias Nest.LLM.StreamConsumer
  alias Nest.Messages.System
  alias Nest.Tokens.Compactor

  require Logger

  @summarization_prompt """
  You are a conversation summarizer.

  Produce a concise prose summary preserving:
    - The user's current goal
    - Key facts established
    - Decisions made
    - Any unresolved TODOs

  Drop redundant tool outputs and resolved sub-tasks. Be brief.
  """

  @type continuation ::
          {:chat_continuation, {String.t()}}
          | {:preflight_continuation, pid()}
          | {:task_compaction_continuation, pid()}

  # Public API

  @doc """
  Spawns a Task that runs the two-pass Compactor on
  `messages_to_compact`, then sends `{:compaction_done,
  new_messages, continuation}` back to `agent_pid`. The
  continuation is whatever was queued to happen after compaction
  (e.g. the next chat turn).
  """
  @spec spawn(pid(), ClientConfig.t(), pos_integer() | nil, [Message.t()], continuation()) ::
          Task.t()
  def spawn(agent_pid, client_config, context_limit, messages_to_compact, continuation) do
    Task.Supervisor.start_child(Nest.Agents.TaskSupervisor, fn ->
      result =
        try do
          llm_call = build_summarization_llm_call(client_config, agent_pid)

          {:ok, Compactor.compact(messages_to_compact, context_limit, llm_call)}
        catch
          kind, reason ->
            Logger.warning(
              "Compaction failed: #{inspect(kind)} #{inspect(reason)}. Proceeding with original messages."
            )

            {:error, {kind, reason}}
        end

      case result do
        {:ok, new_messages} ->
          send(agent_pid, {:compaction_done, new_messages, continuation})

        {:error, reason} ->
          send_failure(agent_pid, messages_to_compact, continuation, reason)
      end
    end)
  end

  @doc """
  Assigns monotonically-increasing message indices starting at
  `start_index`. Pure utility, exposed for the GenServer's
  `archive_and_compact/2` to use.
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

  # For chat and task_compaction continuations, the GenServer's
  # :compaction_done handler treats the input as-is and broadcasts
  # a success log line. For preflight, the task is blocked on a
  # receive and needs an explicit failure message so it can fall
  # back to its existing snapshot.
  defp send_failure(
         agent_pid,
         _messages_to_compact,
         {:preflight_continuation, task_pid},
         reason
       ) do
    send(agent_pid, {:compaction_failed_for_preflight, task_pid, reason})
  end

  defp send_failure(agent_pid, messages_to_compact, continuation, _reason) do
    send(agent_pid, {:compaction_done, messages_to_compact, continuation})
  end

  # The LLM call the compactor uses. Wraps the chat client so the
  # summarization LLM request is routed through the same provider
  # the agent is using (KV cache prefix reuse, etc.).
  #
  # Deltas are sent to `compaction_pid` (the compactor task), not
  # broadcast — we don't want summarization progress to leak into
  # the chat PubSub topic. The compactor task ignores them.
  defp build_summarization_llm_call(%ClientConfig{} = client_config, compaction_pid) do
    fn messages ->
      # Prepend the compactor's summarization system prompt as a
      # `{:system, _}` message. The original system's content is
      # dropped — the compactor builds a fresh conversation for
      # the summarization LLM and doesn't need the agent's
      # session-level instructions.
      request = %RunRequest{
        messages: prepend_summarization_system(messages),
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
        {:ok, stream} ->
          text = consume_quietly(stream, compaction_pid)
          text || ""

        {:error, _reason} ->
          ""
      end
    end
  end

  # Strip any `{:system, _}` messages from the input and prepend
  # the compactor's own summarization system message at position
  # 0. The compactor builds a fresh conversation for the
  # summarization LLM, so the agent's session-level system
  # instructions aren't included.
  defp prepend_summarization_system(messages) do
    summarization_message =
      {:system, %System{content: @summarization_prompt, timestamp: DateTime.utc_now()}}

    messages
    |> List.wrap()
    |> Enum.reject(&match?({:system, _}, &1))
    |> Kernel.++([summarization_message])
  end

  # Consume a streaming response without broadcasting. The
  # `compaction_pid` receives delta messages (so the task can
  # observe progress if it wants), but no PubSub broadcast.
  defp consume_quietly(stream, compaction_pid) do
    consumer = %StreamConsumer{
      on_text: &forward_text_delta(&1, &2, compaction_pid),
      on_thinking: &forward_thinking_delta(&1, &2, compaction_pid),
      on_signature: fn _sig -> :ok end
    }

    {_acc, response, _error, _sent} = StreamConsumer.reduce(stream, consumer)

    case response do
      %RunResponse{text: text} -> text
      _ -> nil
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
