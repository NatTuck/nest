defmodule Nest.Agents.Agent.Restore do
  @moduledoc """
  Pure helpers for populating an agent's `chat_state` after a
  BEAM restart. Lives outside `Nest.Agents.Agent` to keep that
  GenServer module under the 500-line credo limit.

  ## What it does

  The `:user` and `:tool` rows in the `messages` table DO NOT
  carry `api_logs` (the request payloads are large and would
  cause O(N²) storage growth across compactions). On restore
  we replay the live request-payload build via the agent's
  configured client (`state.client_config.client.format_request_payload/2`)
  to produce a wire-format log that matches what the live path
  would have produced, and attach it as a single-element
  `api_logs` list on the runtime message.

  The first user/tool api_log gets sequence `0` (formatted as
  `"<idx>.000"`); `state.chat_state.api_log_sequences` is then
  seeded with `%{idx => 1}` for every user/tool index so the
  NEXT live request picks up at `.001` — no id collision with
  the rebuilt `.000`.

  ## Compaction markers

  The preloaded sequence returned by `Persistence.load_messages/1`
  carries `{:compaction, _}` markers inline — the partition into
  `history` vs `messages` happens at agent-init, not at load.
  The rebuild path filters `{:compaction, _}` tuples out of
  the slice before passing to `client.format_request_payload/2`
  because `OpenAIClient.message_to_wire/1` has no clause for
  `:compaction` (the live path avoids this because it draws
  requests from `state.chat_state.messages`, which excludes
  compaction markers). See `rebuild_request_api_logs/4`.
  """

  alias Nest.Agents.Agent.ChatState
  alias Nest.LLM.ClientConfig
  alias Nest.LLM.RunRequest
  alias Nest.Messages.Compaction, as: CompactionMessage
  alias Nest.Messages.Message

  @doc """
  Rebuild the request api_log for the user/tool message at the
  given index. Walks the slice `Enum.take(messages, idx + 1)`
  from the preloaded sequence to construct the request
  payload, then defers to the agent's configured client.

  The returned log entry matches the wire shape
  `Broadcasts.api_log/4` produces for the live path:
  `%{id, timestamp, type: :request, payload}`.

  ## RunRequest defaults

  `tool_choice: :auto` matches the agent's standard chat
  config (vocation changes mid-conversation aren't supported
  elsewhere). `stream: true, metadata: %{}` mirror the live
  defaults in `ChatTurn.APILog.request/3`. The `opts` arg to
  `format_request_payload/2` is left empty: the wire format
  doesn't carry `base_url`/`api_key`, which are http concerns.
  """
  @spec rebuild_request_api_logs(
          Nest.Agents.Agent.t(),
          [Message.t()],
          non_neg_integer(),
          ClientConfig.t()
        ) :: %{
          id: String.t(),
          timestamp: DateTime.t(),
          type: :request,
          payload: map()
        }
  def rebuild_request_api_logs(state, messages, message_index, %ClientConfig{} = client_config) do
    # Filter `{:compaction, _}` markers out of the slice before
    # the wire-format call. Compaction markers are runtime
    # bookkeeping (they live in `state.chat_state.history`,
    # never in `state.chat_state.messages`) and never reach
    # the LLM in the live path. The preloaded sequence we get
    # here is the full DB sequence (compaction markers inline),
    # so a user/tool index whose slice crosses a marker would
    # otherwise crash `OpenAIClient.message_to_wire/1` — that
    # was the `entire-ox` production regression on BEAM restart.
    slice =
      messages
      |> Enum.take(message_index + 1)
      |> Enum.reject(&match?({:compaction, _}, &1))

    request = %RunRequest{
      messages: slice,
      tools: state.tools,
      tool_choice: :auto,
      model: client_config.model,
      stream: true,
      metadata: %{}
    }

    # Wire format only — `opts` is for http concerns (base_url,
    # api_key) and intentionally omitted. The wire format the
    # live LLM client would receive is the same regardless of
    # the http call.
    payload = client_config.client.format_request_payload(request, [])

    %{
      id: format_sequence_id(message_index, 0),
      timestamp: DateTime.utc_now(),
      type: :request,
      payload: payload
    }
  end

  @doc """
  Compute the per-message sequence map to seed
  `chat_state.api_log_sequences` after restore. For every
  `:user` and `:tool` index in the preloaded sequence (across
  both history and messages), the next sequence number is `1`,
  matching what `Broadcasts.next_api_log_id/2` returns on the
  next call after a sequence-0 entry has been assigned.

  `:assistant` and `:system` messages don't get sequence
  entries here — they're persisted with their own response
  logs and don't trigger new requests from the user/tool
  direction.
  """
  @spec initial_sequences_for([Message.t()]) :: %{optional(non_neg_integer()) => pos_integer()}
  def initial_sequences_for(preloaded) do
    Enum.reduce(preloaded, %{}, fn
      {role, %{index: idx}}, acc when role in [:user, :tool] -> Map.put(acc, idx, 1)
      _, acc -> acc
    end)
  end

  @doc """
  Populate the runtime `api_logs` field on every `:user` and
  `:tool` message in the agent's chat state by replaying the
  request-payload build. Idempotent: if a message already has
  non-empty `api_logs`, it is left alone (forward-compat for
  when we add a `persistence.api_log` flag).

  Also seeds `chat_state.api_log_sequences` with the result of
  `initial_sequences_for/1`. Returns the updated agent state.

  The caller (`Agent.init/1`) passes the FULL preloaded sequence
  (`attrs[:preloaded_messages]`); `seed_from_db/3` already
  partitioned that sequence into the agent's `:history` and
  `:messages` fields, but the rebuild helper re-walks the full
  list so each user/tool index sees its full prior context in
  the rebuilt request payload.
  """
  @spec attach_rebuilt_api_logs(Nest.Agents.Agent.t(), [Message.t()], integer()) ::
          Nest.Agents.Agent.t()
  def attach_rebuilt_api_logs(state, preloaded, _last_compaction_index) do
    client_config = state.client_config

    # Build a map of every user/tool index in the preloaded list
    # to its rebuilt request log. Indexes are computed from the
    # tuples' `index` fields; the rebuild loop looks up the
    # corresponding slice via `Enum.take/2`.
    #
    # Idempotency: skip messages that already carry `api_logs`
    # (forward-compat for a future `persistence.api_log` flag).
    rebuilt_by_index =
      preloaded
      |> Enum.filter(fn
        {:user, %{api_logs: []}} -> true
        {:user, %{api_logs: nil}} -> true
        {:tool, %{api_logs: []}} -> true
        {:tool, %{api_logs: nil}} -> true
        _ -> false
      end)
      |> Map.new(fn {_, %{index: idx}} ->
        {idx, rebuild_request_api_logs(state, preloaded, idx, client_config)}
      end)

    # Patch the messages field on both `history` and `messages`
    # in case the rebuilt index falls on either side of the
    # `last_compaction_index` boundary. (History may contain
    # user/tool messages from before the most recent compaction.)
    initial_sequences = initial_sequences_for(preloaded)

    state = %{
      state
      | chat_state: %{
          state.chat_state
          | history: patch_api_logs(state.chat_state.history, rebuilt_by_index),
            messages: patch_api_logs(state.chat_state.messages, rebuilt_by_index),
            api_log_sequences: Map.merge(state.chat_state.api_log_sequences, initial_sequences)
        }
    }

    state
  end

  # Replace `api_logs` on any message whose index is in the
  # rebuild map. Leaves every other message untouched.
  defp patch_api_logs(messages, rebuilt_by_index) do
    Enum.map(messages, fn
      {role, %{index: idx} = msg} = entry ->
        case Map.fetch(rebuilt_by_index, idx) do
          {:ok, rebuilt} ->
            {role, %{msg | api_logs: [rebuilt]}}

          :error ->
            entry
        end

      {:compaction, %CompactionMessage{}} = entry ->
        entry
    end)
  end

  # Format a sequence id the same way
  # `Broadcasts.next_api_log_id/2` does: zero-padded
  # `<message_index>.<sequence>` (3 digits each). The JS uses
  # `key={log.timestamp}` rather than `log.id`, so id drift is
  # harmless for React reconciliation; preserving the format
  # keeps the wire shape uniform across live and rebuilt logs.
  @spec format_sequence_id(non_neg_integer(), non_neg_integer()) :: String.t()
  defp format_sequence_id(message_index, sequence) do
    :io_lib.format("~3..0B.~3..0B", [message_index, sequence])
    |> IO.iodata_to_binary()
  end

  @doc """
  Reset `chat_state.api_log_sequences` from the given preloaded
  list. Useful when the rebuild needs to defer sequence seeding
  (e.g. test fixtures or a planned `Refresh-from-DB` admin tool).

  Public for testing and the `:api_log_sequences_updated` callback
  pathway; the inline `attach_rebuilt_api_logs/3` already merges
  via `initial_sequences_for/1`.
  """
  @spec reset_sequences(ChatState.t(), [Message.t()]) :: ChatState.t()
  def reset_sequences(%ChatState{} = chat_state, preloaded) do
    %{chat_state | api_log_sequences: initial_sequences_for(preloaded)}
  end
end
